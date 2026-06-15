# Record the README demo GIF with VHS (https://github.com/charmbracelet/vhs).
#
#   brew install vhs        # one-time (pulls ffmpeg + ttyd)
#   vhs scripts/demo.tape   # run from the repo root -> assets/demo.gif
#
# The demo hits the live hex.pm API, so the Sleeps below leave time for the
# inline status to load. Bump them on a slow connection.

Output assets/demo.gif

Require nvim

Set FontSize 18
Set Width 1200
Set Height 720
Set Padding 20
Set Theme "Catppuccin Macchiato"

# Open the sample mix.exs in the isolated demo config.
Hide
Type "nvim -u scripts/demo/init.lua scripts/demo/mix.exs"
Enter
Sleep 2s
Show

# Inline status loads from hex.pm: up to date, upgradable, pinned, non-existent.
Sleep 4s

# Browse published versions for a dependency.
Type "/jason"
Enter
Escape
Type ":HexOutdated versions"
Enter
Sleep 3s
Escape
Sleep 1s

# Upgrade the requirement under the cursor to the latest.
Type ":HexOutdated upgrade"
Enter
Sleep 3s

# Reveal mix.lock context: toggle the lens (locked vs latest under each dep)...
Type ":HexOutdated lock"
Enter
Sleep 3s

# ...then the detail float for a single dependency.
Type "/phoenix"
Enter
Escape
Type ":HexOutdated info"
Enter
Sleep 3s
Type "j"
Sleep 1s
