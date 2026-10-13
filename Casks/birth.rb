cask "birth" do
  version "0.2.11"
  sha256 "eecb9e505fef5c4c0e0ea8e68651901a1377cce290c7ccde29559be709dcff81"

  url "https://github.com/iAmCorey/birth/releases/download/v#{version}/Birth-#{version}.dmg"
  name "Birth"
  desc "Startup item manager"
  homepage "https://github.com/iAmCorey/birth"

  depends_on macos: :sonoma

  app "Birth.app"

  zap trash: "~/Library/Preferences/dev.birth.Birth.plist"

  caveats <<~EOS
    Birth is not notarised by Apple. If macOS blocks the first launch,
    open System Settings > Privacy & Security and select "Open Anyway".

    After upgrading, re-grant Full Disk Access and Automation permissions
    in System Settings by toggling Birth off and back on.
    Removal backups in ~/Library/Application Support/Birth are preserved,
    including when uninstalling with --zap.
  EOS
end
