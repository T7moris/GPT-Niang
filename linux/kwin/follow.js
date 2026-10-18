/* KWin 6 script. Only the widget's geometry and window flags are changed.
 * exchange is a long poll: one D-Bus call in flight, no shell polling loop.
 * Window titles, PIDs and the list of other applications never leave KWin.
 */
(function () {
    "use strict";
    var service = "org.gptniang.KDE";
    var widgetTitle = "GPT娘 · KDE 挂件";
    var selected = null;
    var constraints = [];
    var previous = "";
    var initializedPet = null;

    function rect(g) {
        return {x: g.x, y: g.y, width: g.width, height: g.height};
    }
    function own(w) {
        return w && (w.caption === widgetTitle || w.caption === "GPT娘 · 设置");
    }
    function codex(w) {
        if (!w || own(w) || !w.normalWindow) return false;
        // Match the application's class, never a browser tab/window title.
        var cls = String(w.resourceClass || "").toLowerCase();
        var app = String(w.desktopFileName || "").toLowerCase().split("/").pop().replace(/\.desktop$/, "");
        // The Linux desktop package also ships as ChatGPT with Codex in the
        // same application window. Match that app ID, not its chat titles.
        return /^(codex|chatgpt|com\.openai\.(codex|chatgpt)|openai-codex|codex-desktop)$/.test(cls) || /^(codex|chatgpt|com\.openai\.(codex|chatgpt)|openai-codex|codex-desktop)$/.test(app);
    }
    function onDesktop(w) {
        var desktops = w.desktops || [];
        var desktop = typeof workspace.currentDesktopForScreen === "function" ? workspace.currentDesktopForScreen(w.output) : workspace.currentDesktop;
        var activities = w.activities || [];
        return (!desktops.length || desktops.indexOf(desktop) >= 0) && (!activities.length || activities.indexOf(workspace.currentActivity) >= 0);
    }
    function visible(w) {
        return w && !w.minimized && !w.hidden && !w.hiddenByShowDesktop && onDesktop(w);
    }
    function clearConstraints() {
        if (typeof workspace.unconstrain === "function") {
            constraints.forEach(function (pair) {try {workspace.unconstrain(pair[0], pair[1]);} catch (_) {}});
        }
        constraints = [];
    }
    function tick() {
        var windows = workspace.stackingOrder;
        if (selected && windows.indexOf(selected) < 0) selected = null;
        if (codex(workspace.activeWindow)) selected = workspace.activeWindow;
        if (!selected) {
            for (var n = windows.length - 1; n >= 0; --n) {
                if (codex(windows[n]) && visible(windows[n])) {selected = windows[n]; break;}
            }
        }
        var pet = null;
        for (var i = 0; i < windows.length; ++i) if (windows[i].caption === widgetTitle) pet = windows[i];
        var screens = workspace.screens.map(function (s) {
            return {name:s.name, geometry:rect(s.geometry), workArea:rect(workspace.clientArea(KWin.PlacementArea,s,workspace.currentDesktop))};
        });
        var state = {
            ready:true, target:selected?{id:String(selected.internalId), appId:String(selected.desktopFileName || selected.resourceClass), geometry:rect(selected.frameGeometry), visible:visible(selected), active:selected.active, output:selected.output?selected.output.name:"", moving:selected.move || selected.resize}:null,
            widget:pet?{x:pet.frameGeometry.x,y:pet.frameGeometry.y,width:pet.frameGeometry.width,height:pet.frameGeometry.height,noBorder:pet.noBorder,hidden:pet.hidden}:null,
            cursor:{x:workspace.cursorPos.x,y:workspace.cursorPos.y},
            screens:screens, stacking:typeof workspace.constrain === "function"?"constraints":"raise-order"
        };
        callDBus(service,"/org/gptniang/KDE","org.gptniang.KDE","exchange",JSON.stringify(state),function (reply) {
            try {
            var cfg;
            try {cfg = JSON.parse(reply);} catch (_) {return;}
            // The native window can disappear while the asynchronous exchange
            // is in flight (minimize, close, desktop change). Reacquire every
            // QObject before dereferencing it instead of using the old list.
            windows = workspace.stackingOrder;
            if (selected && windows.indexOf(selected) < 0) selected = null;
            pet = null;
            for (var p = 0; p < windows.length; ++p) if (windows[p].caption === widgetTitle) pet = windows[p];
            if (pet && cfg && cfg.settings) {
                if (initializedPet !== pet && typeof workspace.unconstrain === "function") {
                    // Constraints live in KWin. Recover ones left by an older
                    // bridge before rebuilding, even after a killed process.
                    windows.forEach(function(w) {
                        if (w !== pet) {workspace.unconstrain(w,pet);workspace.unconstrain(pet,w);}
                    });
                    initializedPet = pet;
                    constraints = [];
                    previous = "";
                }
                var settings = cfg.settings;
                pet.noBorder = true;
                pet.skipTaskbar = true;
                pet.skipPager = true;
                pet.skipSwitcher = true;
                var following = settings.mode === "follow" && selected;
                pet.keepAbove = following ? !!selected.keepAbove : settings.alwaysOnTop;
                pet.keepBelow = false;
                if (following) {
                    pet.desktops = selected.desktops;
                    pet.activities = selected.activities;
                } else {
                    pet.desktops = [];
                    pet.activities = [];
                }
                var current = pet.frameGeometry;
                var g = {x:current.x,y:current.y,width:Math.round(280*settings.scale),height:Math.round(362*settings.scale)};
                var area = screens.length ? screens[0].workArea : {x:0,y:0,width:1920,height:1080};
                var x = settings.desktop.x === null ? area.x + area.width - g.width - 24 : settings.desktop.x;
                var y = settings.desktop.y === null ? area.y + area.height - g.height - 24 : settings.desktop.y;
                if (following) {
                    var host = selected.frameGeometry;
                    x = settings.follow.edge === "left" ? host.x + 12 : host.x + host.width - g.width - 12;
                    y = host.y + host.height - g.height - settings.follow.bottom;
                    x = Math.max(host.x,Math.min(x,host.x + host.width - g.width));
                    y = Math.max(host.y,Math.min(y,host.y + host.height - g.height));
                }
                if (cfg.drag) {
                    x = workspace.cursorPos.x - cfg.drag.x;
                    y = workspace.cursorPos.y - cfg.drag.y;
                }
                // Recover off-screen saved positions after unplugging a monitor.
                if (!cfg.drag && screens.length) {
                    var nearest = screens[0].workArea, distance = Infinity;
                    screens.forEach(function (s) {
                        var a = s.workArea;
                        var dx = Math.max(a.x - x,0,x - (a.x + a.width - 1));
                        var dy = Math.max(a.y - y,0,y - (a.y + a.height - 1));
                        if (dx*dx + dy*dy < distance) {distance = dx*dx + dy*dy; nearest = a;}
                    });
                    x = Math.max(nearest.x,Math.min(x,nearest.x + nearest.width - g.width));
                    y = Math.max(nearest.y,Math.min(y,nearest.y + nearest.height - g.height));
                }
                if (Math.abs(current.x-x) >= 1 || Math.abs(current.y-y) >= 1 || Math.abs(current.width-g.width)>=1 || Math.abs(current.height-g.height)>=1)
                    pet.frameGeometry = {x:Math.round(x),y:Math.round(y),width:g.width,height:g.height};
                // Keep the widget directly above Codex, including when it loses
                // focus. Reproduce actual stacking instead of making an overlay.
                var above = following ? windows.slice(windows.indexOf(selected)+1).filter(function(w){return w !== pet && !own(w) && visible(w) && (w.normalWindow || w.dialog);}) : [];
                var signature = following ? String(pet.internalId)+":"+String(selected.internalId)+":"+above.map(function(w){return String(w.internalId);}).join(",") : "";
                if (signature !== previous) {
                    clearConstraints(); previous = signature;
                    if (following && typeof workspace.constrain === "function") {
                        workspace.constrain(selected,pet); constraints.push([selected,pet]);
                        above.forEach(function(w){workspace.constrain(pet,w);constraints.push([pet,w]);});
                    }
                }
                if (following && visible(selected)) {
                    var order = workspace.stackingOrder;
                    if (order.indexOf(pet) < order.indexOf(selected) || above.some(function(w){return order.indexOf(w)<order.indexOf(pet);})) {
                        workspace.raiseWindow(pet);
                        above.forEach(function(w){workspace.raiseWindow(w);});
                    }
                }
            } else if (!pet && previous) {clearConstraints(); previous = "";}
            tick();
            } catch (error) {
                callDBus(service,"/org/gptniang/KDE","org.gptniang.KDE","scriptError",String(error.stack || error));
            }
        });
    }
    tick();
}());
