pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.modules.common

// The bar's effective corner style, per screen.
//
// Whether to hug is a per-monitor question -- one screen can have a maximised
// window while the other does not -- but the widgets that ask are spread across
// twenty-odd files, each instantiated too deep for the bar to hand the answer
// down. So the bar publishes what it decided for its own screen and they look
// it up by theirs.
Singleton {
    id: root

    property var byScreen: ({})

    function publish(screenName, style) {
        if (!screenName || root.byScreen[screenName] === style)
            return;
        // Replaced rather than mutated: QML does not notice a change made inside
        // a var, and every binding reading this would keep the stale value.
        const next = Object.assign({}, root.byScreen);
        next[screenName] = style;
        root.byScreen = next;
    }

    // Falls back to the setting, which is what a widget outside any bar -- or one
    // asking before its bar has published -- should see.
    function corner(screenName) {
        const v = root.byScreen[screenName];
        return v === undefined ? Config.options.bar.cornerStyle : v;
    }
}
