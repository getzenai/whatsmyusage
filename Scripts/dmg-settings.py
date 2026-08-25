# dmgbuild settings for WhatsMyUsage.dmg. Read by Scripts/make-dmg.sh, which
# passes app_path, background_path and dmg_name in with -D.
#
# Coordinates are window points with the origin top left, the same space the
# background is drawn in -- keep them in step with Scripts/dmg_background.py.
import os.path

application = defines["app_path"]  # noqa: F821  (dmgbuild injects `defines`)
appname = os.path.basename(application)

format = "UDZO"          # compressed and read-only: nobody edits a release
volume_name = defines["volume_name"]  # noqa: F821
files = [application]
symlinks = {"Applications": "/Applications"}

# Hide everything the disk image needs but the user should not see.
icon_locations = {appname: (180, 176), "Applications": (480, 176)}
background = defines["background_path"]  # noqa: F821

window_rect = ((200, 200), (660, 400))
default_view = "icon-view"
show_icon_preview = False
icon_size = 128
text_size = 13
label_pos = "bottom"

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
