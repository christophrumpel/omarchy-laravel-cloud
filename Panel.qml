import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Laravel Cloud panel: every application with its environments, the latest
// deployment per environment, and per-row actions (deploy, watch logs in a
// terminal, open the site, open the dashboard). Data comes from
// bin/laravel-cloud-status, which wraps the `cloud` CLI and caches to
// ~/.local/state/omarchy/laravel-cloud/status.json.
Panel {
  id: root
  moduleName: "christophrumpel.laravel-cloud"
  ipcTarget: "christophrumpel.laravel-cloud"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar identifies this panel by the widget mounted in its slot, not by
  // this nested item (see the weather panel for the long version).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string statusScript: pluginDir + "/bin/laravel-cloud-status"
  readonly property string deployScript: pluginDir + "/bin/laravel-cloud-deploy"
  readonly property string monitorScript: pluginDir + "/bin/laravel-cloud-monitor"
  readonly property string setupScript: pluginDir + "/bin/laravel-cloud-setup"
  readonly property string cloudBin: String(setting("cloudBin", "") || "")

  readonly property int refreshIntervalSec: Math.max(30, parseInt(setting("refreshIntervalSec", 300), 10) || 300)
  readonly property int deployPollSec: Math.max(5, parseInt(setting("deployPollSec", 10), 10) || 10)

  // ---- state -------------------------------------------------------------

  property var status: null
  property bool loading: false
  property bool forceStatusRefresh: true
  property bool everLoaded: false
  property double nowMs: Date.now()

  // Environments whose deploy was just triggered from this panel, keyed by
  // environment id → ms timestamp. Paints the row as "deploying" until the
  // CLI shows the new deployment (or a minute passes with nothing showing).
  property var pendingDeploys: ({})
  // Two-step deploy: the first click arms the rocket, the second confirms.
  property string armedEnvId: ""

  readonly property var apps: status && Array.isArray(status.apps) ? status.apps : []
  readonly property string errorText: status && status.error ? String(status.error) : ""
  // Setup states guide the user through commands to run themselves.
  readonly property string errorCode: status && status.code ? String(status.code) : ""
  readonly property bool setupNeeded: ["missing-php", "missing-composer", "missing-cli", "cli-broken", "missing-sockets", "unauthenticated"].indexOf(errorCode) !== -1
  readonly property var setup: status && status.setup ? status.setup : ({})
  readonly property int setupStep: errorCode === "missing-php" ? 0
    : errorCode === "missing-composer" ? 1
    : errorCode === "missing-cli" || errorCode === "cli-broken" ? 2
    : errorCode === "missing-sockets" ? 3 : 4
  readonly property string setupExplanation: {
    if (errorCode === "missing-php") return (String(setup.phpVersion || "") === ""
      ? "PHP is not installed. Install it with Omarchy’s PHP development environment."
      : "PHP " + setup.phpVersion + " is too old. Upgrade with Omarchy’s PHP development environment.")
    if (errorCode === "missing-composer") return "Install Composer using Omarchy’s PHP development environment."
    if (errorCode === "cli-broken") return "The CLI was found but could not start. Run this command to see its error."
    if (errorCode === "missing-cli") return "Install the official Laravel Cloud CLI with Composer."
    if (errorCode === "missing-sockets") return "Browser sign-in opens a local callback server, which needs PHP\u2019s sockets extension. Enable it, then check again."
    return "Connect your Laravel Cloud account to see your applications."
  }
  // Each line reports what we looked for AND what we actually found, so the
  // panel never states a bare requirement the user cannot check themselves.
  // PHP, Composer and the CLI are probed on every run, so their state is
  // always known. Sign-in cannot be probed until the CLI runs, so it stays
  // "unknown" until then rather than posing as a step you could do now.
  readonly property var setupRows: {
    var phpFound = String(setup.phpVersion || "")
    var cliPath = String(setup.cliPath || "")
    var rows = [{
      step: 0,
      state: setup.phpOk ? "ok" : "fail",
      label: "PHP 8.3 or newer",
      detail: setup.phpOk ? "found " + phpFound
        : phpFound === "" ? "not installed"
        : "found " + phpFound + ", too old"
    }]
    // Composer only matters as the means of installing the CLI.
    if (!setup.cliOk)
      rows.push({
        step: 1,
        state: setup.composerOk ? "ok" : "fail",
        label: "Composer",
        detail: setup.composerOk ? "installed" : "not installed"
      })
    rows.push({
      step: 2,
      state: setup.cliOk ? "ok" : "fail",
      label: "Laravel Cloud CLI",
      detail: setup.cliOk ? (cliPath !== "" ? "found at " + cliPath : "installed")
        : cliPath !== "" ? "found at " + cliPath + ", but it will not start"
        : "not installed"
    })
    rows.push({
      step: 3,
      state: !setup.phpOk ? "unknown" : setup.socketsOk ? "ok" : "fail",
      label: "PHP sockets extension",
      detail: !setup.phpOk ? "can\u2019t be checked until PHP is installed"
        : setup.socketsOk ? "enabled"
        : "not enabled, so browser sign-in cannot start"
    })
    // A stored token that the API rejected still counts as "signed in" to the
    // probe, so the error code decides here -- otherwise this row would claim
    // success next to an authentication failure.
    var authFailed = errorCode === "unauthenticated"
    rows.push({
      step: 4,
      state: !setup.cliOk ? "unknown" : (setup.signedIn && !authFailed) ? "ok" : "fail",
      label: "Signed in to Laravel Cloud",
      detail: !setup.cliOk ? "can’t be checked until the CLI is installed"
        : authFailed ? (setup.signedIn ? "sign-in expired, sign in again" : "not signed in")
        : setup.signedIn ? "signed in" : "not signed in"
    })
    return rows
  }

  readonly property string setupCommand: {
    if (errorCode === "missing-php" || errorCode === "missing-composer") return "omarchy install dev-env php"
    if (errorCode === "missing-cli") return "composer global require laravel/cloud-cli"
    if (errorCode === "missing-sockets")
      return "sudo sed -i 's/^;extension=sockets/extension=sockets/' "
        + Util.shellQuote(String(setup.phpIni || "/etc/php/php.ini"))
    if (errorCode === "cli-broken") return Util.shellQuote(String(setup.cliPath || "cloud")) + " --version"
    return "cloud auth"
  }
  property bool commandCopied: false
  onSetupCommandChanged: {
    commandCopied = false
    copiedTimer.stop()
  }

  readonly property var organizations: status && Array.isArray(status.organizations) ? status.organizations : []
  readonly property bool multiOrg: organizations.length > 1
  readonly property string orgSlug: organizations.length === 1 && organizations[0].slug ? String(organizations[0].slug) : ""
  readonly property string orgName: {
    if (organizations.length === 1) return organizations[0].name ? String(organizations[0].name) : ""
    if (organizations.length > 1) return organizations.length + " organizations"
    return ""
  }
  readonly property string fetchedAt: status && status.fetchedAt ? String(status.fetchedAt) : ""

  readonly property var envRows: {
    var rows = []
    for (var i = 0; i < apps.length; i++) {
      var envs = apps[i].environments || []
      for (var j = 0; j < envs.length; j++) rows.push({ app: apps[i], env: envs[j] })
    }
    return rows
  }

  readonly property bool anyDeploying: {
    nowMs
    for (var i = 0; i < envRows.length; i++)
      if (isDeploying(envRows[i].env)) return true
    return false
  }

  readonly property bool anyFailed: {
    for (var i = 0; i < envRows.length; i++)
      if (deployKind(envRows[i].env.latest) === "failed") return true
    return false
  }

  readonly property string tooltipText: {
    if (setupNeeded) return "Laravel Cloud: setup needed. Click to continue."
    if (errorText) return "Laravel Cloud: " + errorText
    if (anyDeploying) return "Laravel Cloud: deployment in progress"
    if (anyFailed) return "Laravel Cloud: a deployment failed"
    return apps.length ? "Laravel Cloud: " + apps.length + " app" + (apps.length === 1 ? "" : "s") : "Laravel Cloud"
  }

  // ---- lifecycle ---------------------------------------------------------

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    // Hide before anything else: a throw in a helper must never leave the
    // panel open with Esc, the bar icon and click-outside all dead.
    root.controller.hide()
    armedEnvId = ""
    setCenterHoverRevealSuppressed(false)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (!root.bar) return
    // Plugins are handed PluginBarApi, where centerHoverRevealSuppressed is
    // readonly -- only the setter works. The direct assignment is the legacy
    // path for older shells that expose the raw Bar.
    if (typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if ("centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- data --------------------------------------------------------------

  function refresh(force) {
    if (statusProc.running) return
    forceStatusRefresh = force !== false
    loading = true
    statusProc.running = true
  }

  function applyStatus(raw) {
    try {
      var parsed = JSON.parse(raw)
      if (parsed && typeof parsed === "object") {
        status = parsed
        everLoaded = true
        reconcilePending()
      }
    } catch (e) {
      status = { fetchedAt: "", error: "could not parse cloud CLI output", code: null, organizations: [], apps: [] }
    }
  }

  // Drop optimistic "deploying" markers once the CLI reports the deployment
  // itself, or after a minute if nothing ever showed up.
  function reconcilePending() {
    var next = {}
    var changed = false
    for (var id in pendingDeploys) {
      var env = findEnv(id)
      var started = pendingDeploys[id]
      var stale = Date.now() - started > 90 * 1000
      var seen = env && env.latest && env.latest.startedAt && Date.parse(env.latest.startedAt) >= started - 60 * 1000
      if (stale || seen) changed = true
      else next[id] = started
    }
    if (changed) pendingDeploys = next
  }

  function findEnv(id) {
    for (var i = 0; i < envRows.length; i++)
      if (envRows[i].env.id === id) return envRows[i].env
    return null
  }

  // ---- deployment semantics ----------------------------------------------

  // "succeeded" | "failed" | "running" | "none"
  function deployKind(latest) {
    if (!latest || !latest.status) return "none"
    var s = String(latest.status).toLowerCase()
    if (s.indexOf("succeed") !== -1 || s.indexOf("success") !== -1) return "succeeded"
    if (s.indexOf("fail") !== -1 || s.indexOf("cancel") !== -1 || s.indexOf("error") !== -1) return "failed"
    return "running"
  }

  function isDeploying(env) {
    if (!env) return false
    if (pendingDeploys[env.id]) return true
    return deployKind(env.latest) === "running"
  }

  function statusColor(env) {
    if (isDeploying(env)) return foreground
    var kind = deployKind(env.latest)
    if (kind === "failed") return urgent
    if (kind === "succeeded") return accent
    return dim
  }

  function statusGlyph(env) {
    if (isDeploying(env)) return "󰦖"
    var kind = deployKind(env.latest)
    if (kind === "failed") return "󰅙"   // nf-md-close_circle
    if (kind === "succeeded") return "󰗠" // nf-md-check_circle
    return "󰝦"                          // nf-md-circle_outline
  }

  function statusLine(env) {
    if (!env) return ""
    if (isDeploying(env)) return "Deploying…"
    var latest = env.latest
    if (!latest) return env.status ? capitalize(env.status) : "No deployments yet"
    var kind = deployKind(latest)
    var when = ago(latest.finishedAt || latest.startedAt)
    var head = kind === "failed" ? "Failed" : (kind === "succeeded" ? "Deployed" : capitalize(String(latest.status).replace(/^[a-z]+\./, "").replace(/[._]/g, " ")))
    var line = head + (when ? " " + when : "")
    if (kind === "failed" && latest.failureReason) line += " · " + humanize(latest.failureReason)
    return line
  }

  function commitLine(latest) {
    if (!latest) return ""
    var parts = []
    if (latest.branchName) parts.push(latest.branchName)
    if (latest.commitHash) parts.push(String(latest.commitHash).slice(0, 7))
    var msg = latest.commitMessage ? String(latest.commitMessage).split("\n")[0].trim() : ""
    var prefix = parts.join(" @ ")
    return msg ? (prefix ? prefix + " · " + msg : msg) : prefix
  }

  function ago(iso) {
    if (!iso) return ""
    var t = Date.parse(iso)
    if (isNaN(t)) return ""
    var s = Math.max(0, Math.round((nowMs - t) / 1000))
    if (s < 60) return "just now"
    var m = Math.round(s / 60)
    if (m < 60) return m + "m ago"
    var h = Math.round(m / 60)
    if (h < 48) return h + "h ago"
    var d = Math.round(h / 24)
    if (d < 60) return d + "d ago"
    return Qt.formatDate(new Date(t), "d MMM yyyy")
  }

  function capitalize(s) {
    s = String(s || "")
    return s.charAt(0).toUpperCase() + s.slice(1)
  }

  function humanize(s) {
    return capitalize(String(s || "").replace(/[._:-]+/g, " ").toLowerCase())
  }

  // ---- actions -----------------------------------------------------------

  function dashboardUrl(app, env) {
    var url = "https://cloud.laravel.com"
    var slug = app && app.organization && app.organization.slug ? String(app.organization.slug) : orgSlug
    if (!slug) return url
    url += "/" + slug
    if (app && app.slug) url += "/" + app.slug
    if (app && app.slug && env && env.slug) url += "/" + env.slug
    return url
  }

  function openUrl(url) {
    if (!url || !root.bar) return
    root.bar.run("xdg-open " + Util.shellQuote(url))
  }

  function openDashboard() { openUrl(dashboardUrl(null, null)) }

  function openSite(env) {
    if (env && env.url) openUrl(env.url)
  }

  function cloudEnv() {
    return cloudBin ? "LARAVEL_CLOUD_BIN=" + Util.shellQuote(cloudBin) + " " : ""
  }

  function tokenIndexArg(app) {
    return app && typeof app.tokenIndex === "number" && app.tokenIndex >= 0 ? String(app.tokenIndex) : ""
  }

  // Sign in interactively in a floating terminal.
  function openSetup(step) {
    if (!root.bar) return
    root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cloudEnv()
      + Util.shellQuote(setupScript) + " " + Util.shellQuote(step))
    root.close()
  }

  function copySetupCommand() {
    if (copyProc.running) return
    commandCopied = false
    copyProc.command = ["wl-copy", "--", setupCommand]
    copyProc.running = true
  }

  function requestDeploy(app, env) {
    if (!app || !env) return
    if (armedEnvId !== env.id) {
      armedEnvId = env.id
      disarmTimer.restart()
      return
    }
    armedEnvId = ""
    disarmTimer.stop()
    startDeploy(app, env)
  }

  function startDeploy(app, env) {
    if (!root.bar) return
    var pending = Util.cloneJson(pendingDeploys)
    pending[env.id] = Date.now()
    pendingDeploys = pending
    root.bar.run(cloudEnv() + "setsid -f " + Util.shellQuote(deployScript) + " "
      + Util.shellQuote(app.name) + " " + Util.shellQuote(env.name) + " " + Util.shellQuote(env.id) + " "
      + Util.shellQuote(app.slug || app.name) + " " + Util.shellQuote(app.repositoryFullName || "")
      + " " + Util.shellQuote(tokenIndexArg(app))
      + " >/dev/null 2>&1")
    // Give the API a moment to register the deployment before polling.
    firstPollTimer.restart()
  }

  // Watch a deployment (or run one) with live output in a floating terminal.
  function openMonitor(app, env) {
    if (!root.bar || !app || !env) return
    var cmd = cloudEnv() + Util.shellQuote(monitorScript) + " " + Util.shellQuote(app.name) + " " + Util.shellQuote(env.name)
      + " " + Util.shellQuote(app.slug || app.name) + " " + Util.shellQuote(app.repositoryFullName || "")
      + " " + Util.shellQuote(tokenIndexArg(app))
    root.bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
  }

  function deployFinished(envId) {
    if (!envId || !pendingDeploys[envId]) return
    var pending = Util.cloneJson(pendingDeploys)
    delete pending[envId]
    pendingDeploys = pending
  }

  // ---- processes and timers ----------------------------------------------

  Process {
    id: copyProc
    onExited: (exitCode, exitStatus) => {
      if (exitCode === 0) {
        root.commandCopied = true
        copiedTimer.restart()
      }
    }
  }

  Timer {
    id: copiedTimer
    interval: 2000
    onTriggered: root.commandCopied = false
  }

  Process {
    id: statusProc
    command: (cloudBin
      ? ["env", "LARAVEL_CLOUD_BIN=" + cloudBin, "bash", root.statusScript]
      : ["bash", root.statusScript]).concat(root.forceStatusRefresh ? ["--force"] : [])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        var raw = String(text || "").trim()
        if (raw) root.applyStatus(raw)
      }
    }
    onExited: root.loading = false
  }

  // Paint the cached snapshot immediately on shell start; the live fetch
  // replaces it a couple of seconds later.
  Process {
    id: cachedProc
    command: ["bash", root.statusScript, "--cached"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw && !root.everLoaded) {
          try {
            var parsed = JSON.parse(raw)
            if (parsed && !parsed.error) root.status = parsed
          } catch (e) {}
        }
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: (root.setupNeeded ? (root.opened ? 5 : 30)
      : (root.anyDeploying ? root.deployPollSec : root.refreshIntervalSec)) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Timer {
    id: firstPollTimer
    interval: 4000
    onTriggered: root.refresh()
  }

  Timer {
    id: disarmTimer
    interval: 3500
    onTriggered: root.armedEnvId = ""
  }

  Timer {
    interval: 30 * 1000
    running: root.opened || root.anyDeploying || Object.keys(root.pendingDeploys).length > 0
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      root.reconcilePending()
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function dashboard(): void { root.openDashboard() }
    function deployFinished(envId: string): void { root.deployFinished(envId) }
  }

  // ---- popup -------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r") root.refresh()
        else if (t === "o") root.openDashboard()
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: scroll.width
          spacing: Style.spacing.panelGap

          PanelHero {
            title: "Laravel Cloud"
            meta: {
              var parts = []
              if (root.orgName) parts.push(root.orgName)
              if (root.loading) parts.push("refreshing…")
              else if (root.fetchedAt) parts.push("updated " + root.ago(root.fetchedAt))
              return parts.join(" · ")
            }
            detail: root.apps.length ? root.apps.length + (root.apps.length === 1 ? " app" : " apps") : ""
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.sm

                PanelActionButton {
                  iconText: "󰏌"  // nf-md-open_in_new
                  tooltipText: "Open dashboard (o)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.openDashboard()
                }

                PanelActionButton {
                  id: refreshButton
                  iconText: "󰑐"  // nf-md-refresh
                  tooltipText: "Refresh (r)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !root.loading
                  onClicked: root.refresh()

                  RotationAnimator on rotation {
                    running: root.loading
                    from: 0; to: 360
                    duration: 900
                    loops: Animation.Infinite
                  }
                  onRotationChanged: if (!root.loading && rotation !== 0) rotation = 0
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---- error / setup / empty states
          Text {
            visible: root.errorText !== "" && !root.setupNeeded
            width: parent.width
            text: root.errorText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          Column {
            id: setupList
            visible: root.setupNeeded
            width: parent.width
            spacing: Style.spacing.md

            Repeater {
              model: root.setupRows

              Text {
                required property var modelData
                width: setupList.width
                text: (modelData.state === "ok" ? "✓ " : modelData.state === "fail" ? "✗ " : "○ ")
                  + modelData.label + " — " + modelData.detail
                // Only the step you can act on now is coloured as a problem;
                // the failures behind it are stated but kept quiet.
                color: modelData.state === "fail" && modelData.step === root.setupStep
                  ? root.urgent : root.foreground
                opacity: modelData.state === "unknown" ? 0.45
                  : modelData.state === "fail" && modelData.step !== root.setupStep ? 0.7 : 1
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: modelData.step === root.setupStep
                wrapMode: Text.Wrap
              }
            }

            PanelSeparator { foreground: root.foreground }

            Text {
              width: parent.width
              text: root.setupExplanation
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Rectangle {
              visible: root.errorCode !== "unauthenticated"
              width: parent.width
              height: commandText.implicitHeight + Style.spacing.md * 2
              color: "transparent"
              border.color: root.dim
              radius: Style.cornerRadius

              Text {
                id: commandText
                x: Style.spacing.md
                y: Style.spacing.md
                width: parent.width - Style.spacing.md * 2
                text: root.setupCommand
                color: root.foreground
                font.family: "monospace"
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WrapAnywhere
              }

              HoverHandler { cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: root.copySetupCommand() }
            }

            Button {
              visible: root.errorCode === "unauthenticated"
              text: "Sign in with browser"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.openSetup("auth")
            }

            Row {
              spacing: Style.spacing.md

              Button {
                visible: root.errorCode !== "unauthenticated"
                text: root.commandCopied ? "Copied" : "Copy command"
                bordered: true
                enabled: !copyProc.running
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.copySetupCommand()
              }

              Button {
                text: "Check again"
                bordered: false
                enabled: !root.loading
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.refresh()
              }
            }

            Text {
              width: parent.width
              visible: root.errorCode !== "unauthenticated"
              text: "Run this in your terminal. We’ll check automatically."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }

          Text {
            visible: root.errorText === "" && root.apps.length === 0
            width: parent.width
            text: root.loading || !root.everLoaded ? "Loading applications…" : "No applications in this organization."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- applications
          Repeater {
            model: root.apps

            Column {
              id: appBlock
              required property var modelData
              required property int index
              readonly property var app: modelData

              width: content.width
              spacing: Style.spacing.sm

              Row {
                width: parent.width
                spacing: Style.spacing.lg

                Text {
                  text: appBlock.app.name || appBlock.app.slug || "app"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  elide: Text.ElideRight
                  width: Math.min(implicitWidth, parent.width - regionText.implicitWidth - Style.spacing.lg)
                  anchors.verticalCenter: parent.verticalCenter

                  HoverHandler { cursorShape: Qt.PointingHandCursor }
                  TapHandler { onTapped: root.openUrl(root.dashboardUrl(appBlock.app, null)) }
                }

                Text {
                  id: regionText
                  text: {
                    var parts = []
                    if (root.multiOrg && appBlock.app.organization && appBlock.app.organization.name) parts.push(appBlock.app.organization.name)
                    if (appBlock.app.region) parts.push(appBlock.app.region)
                    return parts.join(" · ")
                  }
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Repeater {
                model: appBlock.app.environments || []

                CursorSurface {
                  id: envRow
                  required property var modelData
                  required property int index
                  readonly property var env: modelData
                  readonly property bool deploying: {
                    root.nowMs; root.pendingDeploys
                    return root.isDeploying(env)
                  }
                  readonly property bool armed: root.armedEnvId === env.id
                  readonly property color stateColor: {
                    root.nowMs; root.pendingDeploys
                    return root.statusColor(env)
                  }

                  width: content.width
                  height: envContent.implicitHeight + Style.spacing.lg * 2
                  foreground: root.foreground
                  accent: root.accent
                  hasCursor: rowHover.hovered

                  HoverHandler { id: rowHover }

                  Row {
                    id: envContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Style.spacing.rowPaddingX
                    anchors.rightMargin: Style.spacing.lg
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.xl

                    Text {
                      id: stateIcon
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.statusGlyph(envRow.env)
                      color: envRow.stateColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.icon

                      RotationAnimator on rotation {
                        running: envRow.deploying
                        from: 0; to: 360
                        duration: 900
                        loops: Animation.Infinite
                      }
                      onRotationChanged: if (!envRow.deploying && rotation !== 0) rotation = 0
                    }

                    Column {
                      width: parent.width - stateIcon.width - actions.width - parent.spacing * 2
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.xxs

                      Row {
                        width: parent.width
                        spacing: Style.spacing.md

                        Text {
                          text: envRow.env.name || envRow.env.slug || "environment"
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.bold: true
                          elide: Text.ElideRight
                          width: Math.min(implicitWidth, parent.width - stateText.width - parent.spacing)
                        }

                        Text {
                          id: stateText
                          text: {
                            root.nowMs; root.pendingDeploys
                            return root.statusLine(envRow.env)
                          }
                          color: envRow.deploying ? root.foreground : (root.deployKind(envRow.env.latest) === "failed" ? root.urgent : root.dim)
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          elide: Text.ElideRight
                          width: Math.min(implicitWidth, parent.width * 0.7)
                        }
                      }

                      Text {
                        width: parent.width
                        visible: text !== ""
                        text: root.commitLine(envRow.env.latest)
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    Row {
                      id: actions
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.xs

                      // Deploy: first click arms ("Deploy?"), second confirms.
                      BorderSurface {
                        id: deployButton
                        readonly property bool hot: deployHover.hovered
                        implicitWidth: envRow.armed ? deployLabel.implicitWidth + Style.spacing.controlPaddingX * 2 : Style.space(22)
                        implicitHeight: Style.space(22)
                        radius: Style.cornerRadius
                        color: envRow.armed
                          ? Style.selectedFillFor(root.foreground, root.accent)
                          : (hot && !envRow.deploying ? Style.hoverFillFor(root.foreground, root.accent) : "transparent")
                        borderSpec: envRow.armed ? Border.controlSpec("selected", root.foreground, root.accent) : Border.none()
                        opacity: envRow.deploying ? 0.35 : 1

                        Behavior on implicitWidth { NumberAnimation { duration: 90 } }

                        Text {
                          id: deployLabel
                          anchors.centerIn: parent
                          text: envRow.armed ? "Deploy?" : "󱓞"  // nf-md-rocket_launch
                          color: envRow.armed ? Style.selectedStateColor(root.foreground, root.accent) : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: envRow.armed ? Style.font.bodySmall : Style.font.icon
                          font.bold: envRow.armed
                        }

                        HoverHandler { id: deployHover; cursorShape: envRow.deploying ? Qt.ArrowCursor : Qt.PointingHandCursor }
                        TapHandler {
                          enabled: !envRow.deploying
                          onTapped: root.requestDeploy(appBlock.app, envRow.env)
                        }

                        PanelToolTip {
                          visible: deployHover.hovered && !envRow.armed
                          text: envRow.deploying ? "Deployment in progress" : "Deploy " + (appBlock.app.name || "") + " / " + (envRow.env.name || "")
                          fontFamily: root.fontFamily
                        }
                      }

                      PanelActionButton {
                        iconText: "󰆍"  // nf-md-console
                        tooltipText: "Watch deployment in a terminal"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.openMonitor(appBlock.app, envRow.env)
                      }

                      PanelActionButton {
                        iconText: "󰖟"  // nf-md-web
                        tooltipText: envRow.env.url ? "Open " + String(envRow.env.url).replace(/^https?:\/\//, "") : "No URL"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        enabled: !!envRow.env.url
                        onClicked: root.openSite(envRow.env)
                      }

                      PanelActionButton {
                        iconText: "󰅟"  // nf-md-cloud
                        tooltipText: "Open in Laravel Cloud"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.openUrl(root.dashboardUrl(appBlock.app, envRow.env))
                      }
                    }
                  }
                }
              }

              PanelSeparator {
                visible: appBlock.index < root.apps.length - 1
                foreground: root.foreground
                strength: 0.08
              }
            }
          }

          Text {
            width: parent.width
            text: "r refresh · o dashboard · esc close"
            color: Qt.darker(root.foreground, 1.9)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
          }
        }
      }
    }
  }
}
