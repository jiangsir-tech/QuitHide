on run arguments
    if (count of arguments) is not 1 then error "Expected the mounted DMG path."

    set mountPath to item 1 of arguments
    set mountedFolder to POSIX file mountPath as alias
    set backgroundImage to POSIX file (mountPath & "/.background/DMGBackground.png") as alias

    tell application "Finder"
        set mountedDisk to disk of mountedFolder
        open mountedDisk
        delay 1

        set dmgWindow to container window of mountedDisk
        set current view of dmgWindow to icon view
        set toolbar visible of dmgWindow to false
        set statusbar visible of dmgWindow to false
        set pathbar visible of dmgWindow to false
        set bounds of dmgWindow to {120, 120, 780, 560}

        set viewOptions to icon view options of dmgWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 104
        set text size of viewOptions to 14
        set label position of viewOptions to bottom
        set background picture of viewOptions to backgroundImage

        set position of item "QuitHide.app" of mountedDisk to {150, 210}
        set position of item "Applications" of mountedDisk to {510, 210}

        update mountedDisk without registering applications
        delay 2
        close dmgWindow
    end tell
end run
