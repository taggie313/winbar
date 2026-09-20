cask "winbar" do
  # scripts/release.sh (in the winbar repo) rewrites `version` and `sha256` on
  # every release, in the tap's copy of this file. In the repo's template copy
  # the sha256 below is a placeholder that is deliberately NOT a checksum:
  # installing from the template fails loudly, instead of quietly skipping
  # verification the way `sha256 :no_check` would.
  version "0.1.0"
  sha256 "PLACEHOLDER_REPLACED_BY_SCRIPTS_RELEASE_SH"

  # The same disk image the release page offers for download, not a separate
  # archive for Homebrew: one artifact, so what a cask user installs and what a
  # drag-to-Applications user installs are the same bytes, notarized once.
  # Homebrew mounts it, copies Winbar.app out and unmounts it; the /Applications
  # symlink inside is for the people who open it in Finder and is ignored here.
  # Both the image and the app inside carry their own stapled notarization
  # ticket, so Gatekeeper accepts them on first launch even offline.
  url "https://github.com/taggie313/winbar/releases/download/v#{version}/Winbar-#{version}.dmg"
  name "Winbar"
  desc "Menu bar control and tuning recipe for a headless Windows 11 VM in UTM"
  homepage "https://github.com/taggie313/winbar"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Apple silicon only: the whole point is a Windows 11 ARM64 guest running
  # under Hypervisor.framework, and the binary is built for arm64 alone.
  depends_on arch: :arm64
  # A bare symbol means "this release or newer" in current Homebrew; the older
  # `">= :sonoma"` string form still works but is deprecated. Sonoma because
  # the app's deployment target is macOS 14, and scripts/release.sh refuses to
  # ship a binary whose minimum OS is newer than this line promises.
  depends_on macos: :sonoma

  # UTM and Windows App are deliberately NOT `depends_on cask:`. Both are
  # often installed from the Mac App Store or a direct download, and a hard
  # dependency would then try to install the cask over the existing app and
  # fail, taking the Winbar install down with it. The `windows-app` cask is
  # also a .pkg, so depending on it would make installing a menu bar app ask
  # for an administrator password. Instead `winbar setup` looks for each app
  # by bundle id, wherever it came from, and prints `brew install --cask utm`
  # or `brew install --cask windows-app` when one is missing.

  app "Winbar.app"
  # One executable plays both roles, the menu bar app and the `winbar`
  # command, chosen by its arguments. A second, lowercase `winbar` binary
  # cannot sit next to `Winbar` in Contents/MacOS: APFS is case-insensitive by
  # default, so the two names would be the same file. Linking the app's own
  # executable also means the command and the app can never be different
  # versions.
  binary "#{appdir}/Winbar.app/Contents/MacOS/Winbar", target: "winbar"

  # Winbar registers itself with SMAppService when "Launch at Login" is
  # ticked. Homebrew removes the login item for this app's path (and, as a
  # fallback, by name) through System Events, which may cost one Automation
  # prompt during uninstall.
  uninstall quit:       "net.elusive.winbar",
            login_item: "Winbar"

  # Everything Winbar writes on the Mac, and nothing else:
  #   Application Support/Winbar  the VM's certificate file and `winbar
  #                               create`'s job folders
  #   Caches                      the pinned 80 MB UTM Guest Tools installer,
  #                               and the update check's URL cache
  #   HTTPStorages                the update check's URLSession storage
  #   Preferences                 the VM name, RDP host and user. The `winbar`
  #                               command and the app share one defaults
  #                               domain, so this one plist holds both.
  # Deliberately left alone: the RDP certificate trusted in the login keychain,
  # macOS privacy grants, and everything inside the Windows guest. The README's
  # "Uninstall" section explains how to remove or undo each of those.
  zap trash: [
    "~/Library/Application Support/Winbar",
    "~/Library/Caches/net.elusive.winbar",
    "~/Library/HTTPStorages/net.elusive.winbar",
    "~/Library/Preferences/net.elusive.winbar.plist",
  ]

  caveats <<~EOS
    Winbar drives UTM and Windows App, which are separate casks and are not
    installed for you (App Store or direct-download copies work too):

      brew install --cask utm windows-app

    Then point Winbar at your Windows 11 VM and let it walk you through the
    rest. It is safe to re-run; it only changes what still needs changing:

      winbar setup

    macOS will ask whether Winbar (and your terminal app, for the `winbar`
    command) may control UTM. Allow it: that is how Winbar starts, stops and
    reconfigures the VM.

    Excluding the VM from Time Machine is up to you: System Settings >
    General > Time Machine > Options, then add
    ~/Library/Containers/com.utmapp.UTM/Data/Documents
  EOS
end
