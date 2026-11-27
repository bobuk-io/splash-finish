cask "splash-finish" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/bobuk-io/splash-finish/releases/download/v#{version}/SplashFinish-#{version}-universal.zip"
  name "Splash Finish"
  desc "Shared inbox for AI agent notifications and questions"
  homepage "https://bobuk.io/apps/splash-finish/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Splash Finish.app"
  binary "#{appdir}/Splash Finish.app/Contents/MacOS/SplashFinish", target: "splash-finish"

  zap trash: [
    "~/Library/Application Support/Splash Finish",
    "~/Library/Caches/io.bobuk.splash-finish",
    "~/Library/Preferences/io.bobuk.splash-finish.plist",
    "~/Library/Saved Application State/io.bobuk.splash-finish.savedState",
  ]
end
