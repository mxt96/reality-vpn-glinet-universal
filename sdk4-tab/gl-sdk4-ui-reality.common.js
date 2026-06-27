/* GL-SDK4 view: Reality VPN control panel (self-hosted sing-box VLESS+Reality / Hysteria2)
   All router VPN control in one native GL.iNet page. Data via window.$request -> oui rpc "reality". */
(function () {
  "use strict";
  // Read the session id the same way GL's framework does (the Admin-Token cookie).
  // The global window.$request does NOT inject the sid on this firmware, so we send
  // the real sid explicitly in params[0] — exactly the rpc envelope the server accepts.
  function getCookie(n) {
    var m = document.cookie.match(new RegExp('(?:^|;\\s*)' + n + '\\s*=\\s*([^;]+)'));
    return m ? decodeURIComponent(m[1]) : '';
  }
  function call(method, args) {
    var sid = getCookie("Admin-Token") || "";
    return fetch("/rpc", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "same-origin",
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "call", params: [sid, "reality", method, args || {}] })
    }).then(function (r) { return r.json(); }).then(function (j) {
      if (j && j.error) { throw new Error((j.error && j.error.message) || "rpc error"); }
      return j ? j.result : null;
    });
  }

  // ---- country detection -------------------------------------------------
  // Port of the mockup's CC table + flag-from-ISO logic (verified on real data).
  // detectCC(str) reads a country out of a server tag / status field; flags are
  // generated from the ISO code so we ship ZERO image assets (light for the Mudi).
  var CC_RU = {
    US: "United States", GB: "United Kingdom", DE: "Germany", NL: "Netherlands", FR: "France",
    FI: "Finland", RU: "Russia", SE: "Sweden", NO: "Norway", PL: "Poland",
    CH: "Switzerland", AT: "Austria", IT: "Italy", ES: "Spain", CA: "Canada",
    JP: "Japan", SG: "Singapore", HK: "Hong Kong", KR: "Korea", IN: "India",
    AU: "Australia", TR: "Turkey", AE: "UAE", UA: "Ukraine", CZ: "Czechia",
    RO: "Romania", BG: "Bulgaria", LT: "Lithuania", LV: "Latvia", EE: "Estonia",
    IE: "Ireland", DK: "Denmark", BE: "Belgium", LU: "Luxembourg", HU: "Hungary",
    PT: "Portugal", GR: "Greece", IS: "Iceland", IL: "Israel", BR: "Brazil",
    AR: "Argentina", MX: "Mexico", ZA: "South Africa", CN: "China", TW: "Taiwan",
    VN: "Vietnam", TH: "Thailand", ID: "Indonesia", MY: "Malaysia", PH: "Philippines",
    KZ: "Kazakhstan", MD: "Moldova", RS: "Serbia", HR: "Croatia", SK: "Slovakia",
    SI: "Slovenia", AM: "Armenia", GE: "Georgia", BY: "Belarus"
  };
  // keyword (lowercased country name / russian name / major city) -> ISO
  var CC_NAMES = {
    "united states": "US", "usa": "US", "america": "US", "сша": "US",
    "new york": "US", "los angeles": "US", "miami": "US", "chicago": "US", "dallas": "US",
    "united kingdom": "GB", "great britain": "GB", "britain": "GB", "england": "GB",
    "великобритания": "GB", "london": "GB", "лондон": "GB", "uk": "GB",
    "germany": "DE", "германия": "DE", "frankfurt": "DE", "франкфурт": "DE",
    "berlin": "DE", "берлин": "DE", "munich": "DE", "мюнхен": "DE", "deutschland": "DE",
    "netherlands": "NL", "holland": "NL", "нидерланды": "NL", "amsterdam": "NL", "амстердам": "NL",
    "france": "FR", "франция": "FR", "paris": "FR", "париж": "FR", "marseille": "FR",
    "finland": "FI", "финляндия": "FI", "helsinki": "FI", "хельсинки": "FI",
    "russia": "RU", "россия": "RU", "moscow": "RU", "москва": "RU", "saint petersburg": "RU", "spb": "RU",
    "sweden": "SE", "швеция": "SE", "stockholm": "SE", "стокгольм": "SE",
    "norway": "NO", "норвегия": "NO", "oslo": "NO",
    "poland": "PL", "польша": "PL", "warsaw": "PL", "варшава": "PL",
    "switzerland": "CH", "швейцария": "CH", "zurich": "CH", "geneva": "CH",
    "austria": "AT", "австрия": "AT", "vienna": "AT", "вена": "AT",
    "italy": "IT", "италия": "IT", "milan": "IT", "rome": "IT", "milano": "IT",
    "spain": "ES", "испания": "ES", "madrid": "ES", "barcelona": "ES",
    "canada": "CA", "канада": "CA", "toronto": "CA", "montreal": "CA",
    "japan": "JP", "япония": "JP", "tokyo": "JP", "токио": "JP", "osaka": "JP",
    "singapore": "SG", "сингапур": "SG",
    "hong kong": "HK", "hongkong": "HK", "гонконг": "HK",
    "korea": "KR", "корея": "KR", "seoul": "KR", "сеул": "KR",
    "india": "IN", "индия": "IN", "mumbai": "IN", "delhi": "IN",
    "australia": "AU", "австралия": "AU", "sydney": "AU",
    "turkey": "TR", "турция": "TR", "istanbul": "TR", "стамбул": "TR",
    "emirates": "AE", "dubai": "AE", "дубай": "AE", "оаэ": "AE",
    "ukraine": "UA", "украина": "UA", "kyiv": "UA", "kiev": "UA", "киев": "UA",
    "czech": "CZ", "чехия": "CZ", "prague": "CZ", "прага": "CZ",
    "romania": "RO", "румыния": "RO", "bucharest": "RO",
    "bulgaria": "BG", "болгария": "BG", "sofia": "BG",
    "lithuania": "LT", "литва": "LT", "vilnius": "LT", "вильнюс": "LT",
    "latvia": "LV", "латвия": "LV", "riga": "LV",
    "estonia": "EE", "эстония": "EE", "tallinn": "EE",
    "ireland": "IE", "ирландия": "IE", "dublin": "IE",
    "denmark": "DK", "дания": "DK", "copenhagen": "DK",
    "belgium": "BE", "бельгия": "BE", "brussels": "BE",
    "luxembourg": "LU", "люксембург": "LU",
    "hungary": "HU", "венгрия": "HU", "budapest": "HU",
    "portugal": "PT", "португалия": "PT", "lisbon": "PT",
    "greece": "GR", "греция": "GR", "athens": "GR",
    "iceland": "IS", "исландия": "IS", "reykjavik": "IS",
    "israel": "IL", "израиль": "IL", "tel aviv": "IL",
    "brazil": "BR", "бразилия": "BR", "sao paulo": "BR",
    "argentina": "AR", "аргентина": "AR",
    "mexico": "MX", "мексика": "MX",
    "china": "CN", "китай": "CN", "shanghai": "CN", "beijing": "CN",
    "taiwan": "TW", "тайвань": "TW", "taipei": "TW",
    "vietnam": "VN", "вьетнам": "VN",
    "thailand": "TH", "таиланд": "TH", "bangkok": "TH",
    "indonesia": "ID", "индонезия": "ID", "jakarta": "ID",
    "malaysia": "MY", "малайзия": "MY", "kuala lumpur": "MY",
    "philippines": "PH", "филиппины": "PH", "manila": "PH",
    "kazakhstan": "KZ", "казахстан": "KZ", "almaty": "KZ",
    "moldova": "MD", "молдова": "MD", "chisinau": "MD",
    "serbia": "RS", "сербия": "RS", "belgrade": "RS",
    "croatia": "HR", "хорватия": "HR",
    "slovakia": "SK", "словакия": "SK",
    "slovenia": "SI", "словения": "SI",
    "armenia": "AM", "армения": "AM", "yerevan": "AM",
    "georgia": "GE", "грузия": "GE", "tbilisi": "GE",
    "belarus": "BY", "беларусь": "BY", "minsk": "BY"
  };
  // longest keys first so "hong kong" beats a stray "kong" etc.
  var CC_NAME_KEYS = Object.keys(CC_NAMES).sort(function (a, b) { return b.length - a.length; });

  function isoFlag(iso) {
    iso = (iso || "").toUpperCase();
    if (!/^[A-Z]{2}$/.test(iso)) return "";
    return String.fromCodePoint(0x1F1E6 + iso.charCodeAt(0) - 65, 0x1F1E6 + iso.charCodeAt(1) - 65);
  }
  function flagToIso(s) {
    var m = (s || "").match(/[\uD83C][\uDDE6-\uDDFF][\uD83C][\uDDE6-\uDDFF]/);
    if (!m) return "";
    return String.fromCharCode(65 + (m[0].charCodeAt(1) - 0xDDE6)) +
           String.fromCharCode(65 + (m[0].charCodeAt(3) - 0xDDE6));
  }
  function detectCC(str) {
    str = String(str || "");
    var fi = flagToIso(str); if (fi) return fi;
    var low = str.toLowerCase();
    for (var i = 0; i < CC_NAME_KEYS.length; i++) {
      if (low.indexOf(CC_NAME_KEYS[i]) !== -1) return CC_NAMES[CC_NAME_KEYS[i]];
    }
    // bare ISO token, e.g. "DE-19" / "NL44"
    var toks = low.split(/[^a-z]+/);
    for (var j = 0; j < toks.length; j++) {
      if (toks[j].length === 2 && CC_RU[toks[j].toUpperCase()]) return toks[j].toUpperCase();
    }
    return "";
  }
  function famOf(sv) {
    if (sv && sv.fam) return sv.fam;
    var ty = sv && sv.type;
    if (ty === "hysteria2") return "hysteria2";
    if (ty === "trojan") return "trojan";
    if (ty === "shadowsocks") return "shadowsocks";
    if (ty === "vless") return "reality"; // best guess if backend didn't send fam
    return ty || "";
  }
  var FAM_LABEL = { reality: "Reality", tls: "VLESS-TLS", trojan: "Trojan", shadowsocks: "Shadowsocks", hysteria2: "Hysteria2" };
  function famLabel(f) { return FAM_LABEL[f] || f || "?"; }
  function isAutoMode(m) { return m === "auto" || m === "auto-reality" || m === "auto-hy2" || m === "auto-fav"; }
  // ping color buckets (green / yellow / red)
  function pingColor(ms) {
    ms = Number(ms);
    if (!isFinite(ms) || ms < 0) return "#e5484d";
    return ms < 150 ? "#0f9d58" : (ms < 350 ? "#b9821a" : "#e5484d");
  }

  // ---- palette (authentic GL.iNet) ----
  var C = {
    blue: "#3c5bd6", bluebg: "#eaefff", red: "#e5484d", se: "#8a8f99", tx: "#1f2430",
    line: "#e7e9ef", gr: "#0f9d58", ye: "#b9821a"
  };

  return {
    name: "realityview",
    data: function () {
      return {
        loaded: false, err: false, busy: false,
        st: {},                 // last get_status result
        vpnOn: false, ksOn: false, tunneled: false,
        servers: [], serversLoaded: false,
        addLink: "", addName: "", addMsg: "", addOk: false, adding: false, showAdd: false,
        delTag: "",             // server row armed for delete (two-tap confirm)
        spd: null, spdRunning: false,
        traf: { upS: 0, downS: 0, up: 0, down: 0, conns: 0, ok: false },
        ver: { installed: "", latest: "", update: false }, verLoaded: false,
        checking: false, updating: false, updateMsg: "",
        subs: [], subsLoaded: false, subUrl: "", subName: "", subMsg: "", subOk: false, subBusy: false, refreshingSubs: false,
        pings: {}, pinging: false,
        ccSel: {},                // selected country ISO codes (multi-select); empty = none shown
        ccInit: false,            // have we auto-selected all countries once?
        prSel: "all"              // protocol family filter: all|reality|tls|trojan|shadowsocks|hysteria2
      };
    },
    created: function () {
      this.refresh();
      this.loadServers();
      this.pingServers();
      this.loadSubs();
      this.checkUpdate();
      var self = this;
      this._timer = setInterval(function () { if (!self.busy) self.refresh(); }, 15000);
      // live traffic: poll fast (every 2s) so the user can SEE data flowing through
      // the tunnel = proof the connection is real. Cheap single clash call.
      this._trafPrev = null;
      this._trafTimer = setInterval(function () { self.pollTraffic(); }, 2000);
      this.pollTraffic();
    },
    beforeDestroy: function () { if (this._timer) clearInterval(this._timer); if (this._trafTimer) clearInterval(this._trafTimer); if (this._delTimer) clearTimeout(this._delTimer); },
    methods: {
      refresh: function () {
        var self = this;
        this.spinning = true;
        return call("get_status").then(function (r) {
          self.spinning = false; self.loaded = true;
          if (r && r.err_msg) { self.err = true; return; }
          self.err = false; self.st = r || {};
          self.vpnOn = !!self.st.running; self.ksOn = !!self.st.killswitch;
          // "tunneled" = a real server is actually carrying traffic, not just the
          // sing-box process being alive. With no server the config routes DIRECT,
          // so running===true but active==="direct" must NOT read as "protected".
          self.tunneled = !!self.st.running && !!self.st.active && self.st.active !== "direct";
        }).catch(function () { self.spinning = false; self.loaded = true; self.err = true; });
      },
      loadServers: function () {
        var self = this;
        return call("list_servers").then(function (r) {
          self.serversLoaded = true;
          self.servers = (r && r.servers) ? r.servers : [];
          // First load: pre-select ALL detected countries so the list shows everything.
          if (!self.ccInit && self.servers.length) {
            var sel = {};
            self.servers.forEach(function (sv) { sel[detectCC(sv.tag) || "?"] = 1; });
            self.ccSel = sel; self.ccInit = true;
          }
        }).catch(function () { self.serversLoaded = true; });
      },
      pingServers: function () {
        var self = this; this.pinging = true;
        return call("ping_servers").then(function (r) {
          self.pinging = false; self.pings = (r && r.pings) ? r.pings : {};
        }).catch(function () { self.pinging = false; });
      },
      loadSubs: function () {
        var self = this;
        return call("list_subs").then(function (r) {
          self.subsLoaded = true;
          self.subs = (r && r.subs) ? r.subs : [];
        }).catch(function () { self.subsLoaded = true; });
      },
      addSub: function () {
        var self = this; var url = (this.subUrl || "").trim();
        if (!/^https?:\/\//i.test(url)) { this.subOk = false; this.subMsg = "Subscription URL (https://…)"; return; }
        this.subBusy = true; this.subMsg = "";
        call("add_sub", { url: url, name: (this.subName || "").trim() }).then(function (r) {
          self.subBusy = false;
          if (r && r.ok) {
            self.subUrl = ""; self.subName = ""; self.subOk = true;
            self.subMsg = "Added — " + (r.added || 0) + " servers";
            self.loadSubs(); self.loadServers();
          } else { self.subOk = false; self.subMsg = (r && r.msg) ? r.msg : "Couldn't add subscription"; }
        }).catch(function () { self.subBusy = false; self.subOk = false; self.subMsg = "Couldn't add subscription"; });
      },
      delSub: function (id) {
        var self = this; this.subBusy = true;
        call("del_sub", { id: id }).then(function () {
          self.subBusy = false; self.loadSubs(); self.loadServers();
        }).catch(function () { self.subBusy = false; self.loadSubs(); self.loadServers(); });
      },
      refreshSubs: function () {
        var self = this; this.refreshingSubs = true; this.subMsg = "";
        call("refresh_subs", { id: "all" }).then(function (r) {
          self.refreshingSubs = false;
          if (r && r.ok) {
            self.subOk = true;
            self.subMsg = "Updated — " + (r.added || 0) + " new, " + (r.removed || 0) + " removed";
            self.loadSubs(); self.loadServers();
          } else { self.subOk = false; self.subMsg = (r && r.msg) ? r.msg : "Update failed"; }
        }).catch(function () { self.refreshingSubs = false; self.subOk = false; self.subMsg = "Update failed"; });
      },
      fmtAgo: function (epoch) {
        epoch = Number(epoch) || 0; if (!epoch) return "never";
        var now = Math.floor((Date.now ? Date.now() : new Date().getTime()) / 1000);
        var d = now - epoch; if (d < 0) d = 0;
        if (d < 60) return "just now";
        if (d < 3600) return Math.floor(d / 60) + " min ago";
        if (d < 86400) return Math.floor(d / 3600) + " h ago";
        return Math.floor(d / 86400) + " d ago";
      },
      fmtDate: function (epoch) {
        epoch = Number(epoch) || 0; if (!epoch) return "";
        var dt = new Date(epoch * 1000);
        function p(n) { return (n < 10 ? "0" : "") + n; }
        return p(dt.getDate()) + "." + p(dt.getMonth() + 1) + "." + dt.getFullYear();
      },
      toggleVpn: function (val) {
        var self = this; this.busy = true; this.vpnOn = val;
        call("set_enabled", { on: val }).then(function () {
          setTimeout(function () { self.busy = false; self.refresh(); }, val ? 2500 : 3500);
        }).catch(function () { self.busy = false; self.refresh(); });
      },
      toggleKs: function (val) {
        var self = this; this.busy = true; this.ksOn = val;
        call("set_killswitch", { on: val }).then(function () {
          self.busy = false; self.refresh();
        }).catch(function () { self.busy = false; self.refresh(); });
      },
      setProto: function (key) {
        if (this.busy) return;
        var self = this; this.busy = true;
        function doSel() {
          call("set_proto", { proto: key }).then(function () {
            setTimeout(function () { self.busy = false; self.refresh(); }, 2500);
          }).catch(function () { self.busy = false; self.refresh(); });
        }
        // If the VPN is OFF, selecting a server / Auto has no effect — there's no running
        // sing-box (clash API down) to apply the selection, so the tap silently did
        // nothing. Tapping a server should CONNECT to it: turn the tunnel on first, give
        // it time to come up, then apply the selection.
        if (!this.vpnOn) {
          this.vpnOn = true;
          call("set_enabled", { on: true }).then(function () {
            setTimeout(doSel, 3000);
          }).catch(function () { self.busy = false; self.refresh(); });
        } else {
          doSel();
        }
      },
      // ---- new filter / selection helpers ----
      toggleAdd: function () { this.showAdd = !this.showAdd; },
      toggleCC: function (iso) {
        var sel = {}; for (var k in this.ccSel) sel[k] = this.ccSel[k];
        if (sel[iso]) delete sel[iso]; else sel[iso] = 1;
        this.ccSel = sel;
      },
      selectAllCC: function (keys, allOn) {
        if (allOn) { this.ccSel = {}; return; }
        var sel = {}; keys.forEach(function (k) { sel[k] = 1; }); this.ccSel = sel;
      },
      setPr: function (key) { this.prSel = key; },
      goAuto: function () {
        // Auto over the favorites pool. Backend falls back to plain "auto" if the
        // auto-fav urltest group isn't present (no favorites yet).
        this.setProto("auto-fav");
      },
      addServer: function () {
        var self = this; var raw = (this.addLink || "").trim();
        if (!raw) { this.addMsg = "Paste a link, list, or subscription"; return; }
        // Bulk import (Shadowrocket-style): multi-line list, an http(s) subscription
        // URL, or a base64 blob -> import_links. A single scheme link -> normal add.
        var lines = raw.split(/\r?\n/).map(function (s) { return s.trim(); }).filter(Boolean);
        this.adding = true; this.addMsg = "";
        // De-dup with the Subscriptions card: a single http(s) URL IS a subscription, so
        // route it to add_sub (stored + auto-refreshed) instead of a one-shot import_links.
        // Otherwise the same URL behaves differently depending on which box you paste it in.
        if (lines.length === 1 && /^https?:\/\//i.test(raw)) {
          call("add_sub", { url: raw, name: (this.addName || "").trim() }).then(function (r) {
            self.adding = false;
            if (r && r.ok) {
              self.addLink = ""; self.addName = ""; self.addOk = true; self.showAdd = false;
              self.addMsg = "Subscription added — " + (r.added || 0) + " servers";
              self.loadSubs(); self.loadServers();
            } else { self.addOk = false; self.addMsg = (r && r.msg) ? r.msg : "Couldn't add subscription"; }
          }).catch(function () { self.adding = false; self.addOk = false; self.addMsg = "Couldn't add subscription"; });
          return;
        }
        // Bulk import (Shadowrocket-style): multi-line link list or a base64 blob.
        var isBulk = lines.length > 1 || (lines.length === 1 && raw.indexOf("://") < 0);
        if (isBulk) {
          call("import_links", { text: raw }).then(function (r) {
            self.adding = false;
            if (r && r.ok && r.added > 0) {
              self.addLink = ""; self.addName = ""; self.addOk = true; self.showAdd = false;
              self.addMsg = "Added " + r.added + (r.failed ? (", skipped " + r.failed) : "");
              self.loadServers();
            } else { self.addOk = false; self.addMsg = (r && r.added === 0) ? "No valid configs found" : ((r && r.msg) ? r.msg : "Import failed"); }
          }).catch(function () { self.adding = false; self.addOk = false; self.addMsg = "Import failed"; });
          return;
        }
        call("add_server", { link: raw, name: (this.addName || "").trim() }).then(function (r) {
          self.adding = false;
          if (r && r.ok) { self.addLink = ""; self.addName = ""; self.addMsg = ""; self.showAdd = false; self.loadServers(); }
          else { self.addOk = false; self.addMsg = (r && r.msg) ? r.msg : "Couldn't add server"; }
        }).catch(function () { self.adding = false; self.addOk = false; self.addMsg = "Couldn't add server"; });
      },
      delServer: function (tag) {
        // No window.confirm() here: GL's embedded panel webview can silently
        // suppress confirm() (returns false) -> the delete would never fire.
        var self = this; this.busy = true; this.delTag = "";
        call("del_server", { tag: tag }).then(function () {
          self.busy = false; self.cancelEdit(); self.loadServers();
        }).catch(function () { self.busy = false; self.cancelEdit(); self.loadServers(); });
      },
      // Two-tap delete on a server row: first tap on the small ✕ arms the row
      // (turns into "Удалить?"), second tap confirms -> delServer. confirm() is
      // unreliable in GL's webview, so we use this in-UI confirm instead.
      armDel: function (tag) {
        var self = this;
        if (this.delTag === tag) { this.delServer(tag); return; }
        this.delTag = tag;
        // auto-disarm so a stray tap can't leave a row "hot"
        if (this._delTimer) clearTimeout(this._delTimer);
        this._delTimer = setTimeout(function () { if (self.delTag === tag) self.delTag = ""; }, 3500);
      },
      setFav: function (sv) {
        // Toggle ★ on a server. Backend writes /etc/sing-box/favorites + rebuilds the
        // "auto-fav" urltest pool. Optimistic UI; reload to reflect the rebuilt list.
        var self = this; var newOn = !sv.fav; sv.fav = newOn;
        call("set_fav", { tag: sv.tag, on: newOn ? 1 : 0 }).then(function () { self.loadServers(); })
          .catch(function () { sv.fav = !newOn; });
      },
      setFavBulk: function (tags, on) {
        // Star/unstar MANY servers at once = the currently-shown (filtered) set, so the
        // "Auto ★" pool becomes exactly your filter in one tap. ONE backend rebuild, not N
        // (matters with 100+ servers from a subscription).
        if (!tags || !tags.length) return;
        var self = this; this.busy = true;
        call("set_fav_bulk", { tags: tags, on: on ? 1 : 0 })
          .then(function () { self.busy = false; self.loadServers(); })
          .catch(function () { self.busy = false; self.loadServers(); });
      },
      // edit-server UI was removed (rows are tap-to-connect + ✕-delete); cancelEdit is
      // kept only to reset the delete/edit state from delServer.
      cancelEdit: function () { this.delTag = ""; },
      fmtBytes: function (n) {
        n = Number(n) || 0; if (n < 0) n = 0;
        var u = ["B", "KB", "MB", "GB", "TB"], i = 0;
        while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
        return (i === 0 ? Math.round(n) : n.toFixed(n < 10 ? 1 : 0)) + " " + u[i];
      },
      // bytes/sec -> Mbit/s string
      mbits: function (bps) { return ((Number(bps) || 0) * 8 / 1000000).toFixed(1); },
      pollTraffic: function () {
        var self = this;
        if (!this.vpnOn) { this.traf.ok = false; this._trafPrev = null; this.traf.upS = 0; this.traf.downS = 0; return; }
        call("get_traffic").then(function (r) {
          if (!r) return;
          var now = (Date.now ? Date.now() : new Date().getTime());
          var p = self._trafPrev;
          if (p && now > p.t) {
            var dt = (now - p.t) / 1000;
            self.traf.upS = Math.max(0, (r.up_total - p.up) / dt);
            self.traf.downS = Math.max(0, (r.down_total - p.down) / dt);
          }
          self.traf.up = r.up_total; self.traf.down = r.down_total; self.traf.conns = r.conns || 0; self.traf.ok = true;
          self._trafPrev = { t: now, up: r.up_total, down: r.down_total };
        }).catch(function () {});
      },
      runSpeedtest: function () {
        var self = this; this.spdRunning = true; this.spd = null;
        call("speedtest").then(function (r) { self.spdRunning = false; self.spd = r || {}; })
          .catch(function () { self.spdRunning = false; self.spd = { down: "0.0", up: "0.0" }; });
      },
      checkUpdate: function () {
        var self = this; this.checking = true; this.updateMsg = "";
        return call("check_update").then(function (r) {
          self.checking = false; self.verLoaded = true; self.ver = r || {};
        }).catch(function () { self.checking = false; self.verLoaded = true; });
      },
      doUpdate: function () {
        var self = this; this.updating = true; this.updateMsg = "Update scheduled — installing, the page will reload…";
        call("do_update").then(function (r) {
          if (r && r.msg) self.updateMsg = r.msg + " — the page will reload.";
          // the installer restarts services and this very tab; reload after ~85s to
          // pick up the new version + confirmation.
          setTimeout(function () { try { location.reload(); } catch (e) {} }, 85000);
        }).catch(function () { self.updating = false; self.updateMsg = "Couldn't start the update"; });
      }
    },
    render: function (h) {
      var t = this, s = t.st || {};

      // ---------- small style helpers ----------
      function card(children, pad) {
        return h("gl-card", [h("div", { staticClass: "main", style: { padding: (pad == null ? "16px" : pad) } }, children)]);
      }
      function ctitle(txt, cnt) {
        return h("div", { style: { fontSize: "13px", fontWeight: "700", color: "#3a3f4b", marginBottom: "12px", display: "flex", justifyContent: "space-between", alignItems: "center" } }, [
          h("span", [t._v(txt)]),
          cnt != null ? h("span", { style: { fontSize: "12px", color: C.se, fontWeight: "600" } }, [t._v(cnt)]) : null
        ]);
      }
      function chip(children, on, onclick) {
        return h("span", {
          style: {
            border: "1px solid " + (on ? C.blue : "#d7dbe4"), borderRadius: "999px", padding: "6px 12px",
            fontSize: "13px", fontWeight: "600", background: on ? C.blue : "#fff", color: on ? "#fff" : C.tx,
            cursor: "pointer", whiteSpace: "nowrap", userSelect: "none", display: "inline-block"
          },
          on: { click: onclick }
        }, children);
      }
      function pillBtn(label, badge, opts) {
        opts = opts || {};
        var active = opts.active;
        return h("div", {
          style: {
            fontSize: "14px", fontWeight: "700", borderRadius: "22px", padding: "12px 18px",
            border: "1.5px solid " + (active ? C.red : "#cdd2de"), background: active ? C.red : "#fff",
            color: active ? "#fff" : C.blue, cursor: "pointer", width: "100%", display: "flex",
            alignItems: "center", justifyContent: "center", gap: "8px", marginBottom: "13px", userSelect: "none"
          },
          on: { click: opts.onClick }
        }, [
          t._v(label),
          badge != null ? h("span", {
            style: {
              marginLeft: "auto", fontSize: "11px", fontWeight: "800", padding: "3px 9px", borderRadius: "999px",
              background: active ? "rgba(255,255,255,.22)" : C.bluebg, color: active ? "#fff" : C.blue
            }
          }, [t._v(badge)]) : null
        ]);
      }

      // ======================================================================
      // 1) NETWORK STATUS HEADER
      // ======================================================================
      var tun = t.tunneled;
      // VPN off but we still know the real (direct) egress from get_status/geo cache ->
      // show the CURRENT (direct) connection instead of blank dashes (mason's bug:
      // "когда впн выключен то данные по текущему подключению не определяются").
      var hasGeo = !!(s.egress || s.country);
      var direct = !tun && hasGeo;          // VPN off, internet up: show the direct egress
      var live = tun || direct;
      var activeSv = (t.servers || []).filter(function (x) { return x.tag === s.active; })[0];
      var hdrCC = detectCC(s.country || s.active || "");
      var hdrFlag = !live ? "🚫" : (isoFlag(hdrCC) || "🌐");
      var hdrCountry = !live ? "Not connected" : (CC_RU[hdrCC] || s.country || "—");
      var hdrProto = tun ? (activeSv ? famLabel(famOf(activeSv)) : (s.protocol || "")) : "Direct (no VPN)";
      var hdrSub = !live ? "—" : ([s.city, hdrProto].filter(Boolean).join(" · ") || "—");

      function cell(label, valNode, borderRight) {
        return h("div", { style: { padding: "11px 16px", borderTop: "1px solid " + C.line, borderRight: borderRight ? "1px solid " + C.line : "none" } }, [
          h("div", { style: { fontSize: "11px", color: C.se, fontWeight: "600" } }, [t._v(label)]),
          valNode
        ]);
      }
      function dim() { return h("div", { style: { fontSize: "15px", fontWeight: "700", marginTop: "3px", color: "#c4c8d2" } }, [t._v("—")]); }
      function val(text, unit, color) {
        if (text == null || text === "") return dim();
        return h("div", { style: { fontSize: "15px", fontWeight: "700", marginTop: "3px", color: color || C.tx } }, [
          t._v(String(text)),
          unit ? h("span", { style: { fontSize: "11px", color: C.se, fontWeight: "600", marginLeft: "2px" } }, [t._v(unit)]) : null
        ]);
      }
      var pingNode = (live && s.ping) ? val(s.ping, "ms", pingColor(s.ping)) : dim();
      var dnNode = (tun && t.traf.ok) ? val(t.mbits(t.traf.downS), "Mbit/s") : dim();
      var upNode = (tun && t.traf.ok) ? val(t.mbits(t.traf.upS), "Mbit/s") : dim();

      var netCard = h("gl-card", [h("div", { staticClass: "main", style: { padding: "0" } }, [
        h("div", { style: { display: "flex", alignItems: "center", gap: "12px", padding: "15px 16px" } }, [
          h("span", { style: { fontSize: "30px", lineHeight: "1" } }, [t._v(hdrFlag)]),
          h("div", { style: { flex: "1", minWidth: "0" } }, [
            h("div", { style: { fontSize: "17px", fontWeight: "800" } }, [t._v(hdrCountry)]),
            h("div", { style: { fontSize: "12.5px", color: C.se, marginTop: "1px" } }, [t._v(hdrSub)])
          ]),
          tun ? h("span", { style: { display: "flex", alignItems: "center", gap: "6px", fontSize: "12px", fontWeight: "700", color: C.gr, background: "#e8f8f0", padding: "4px 10px", borderRadius: "999px" } }, [
            h("span", { style: { width: "8px", height: "8px", borderRadius: "50%", background: C.gr } }),
            t._v("Online")
          ]) : (direct ? h("span", { style: { display: "flex", alignItems: "center", gap: "6px", fontSize: "12px", fontWeight: "700", color: "#b9821a", background: "#fff6e6", padding: "4px 10px", borderRadius: "999px" } }, [
            h("span", { style: { width: "8px", height: "8px", borderRadius: "50%", background: "#d98a00" } }),
            t._v("No VPN")
          ]) : null)
        ]),
        h("div", { style: { display: "grid", gridTemplateColumns: "1fr 1fr" } }, [
          cell("IP", live ? val(s.egress) : dim(), true),
          cell("PING", pingNode, false),
          cell("DOWNLOAD ↓", dnNode, true),
          cell("UPLOAD ↑", upNode, false)
        ])
      ])]);

      // ======================================================================
      // 2) CONTROLS (VPN master + kill switch) — preserved functionality
      // ======================================================================
      function toggleRow(label, sub, value, handler) {
        return h("div", { style: { display: "flex", justifyContent: "space-between", alignItems: "center" } }, [
          h("div", [
            h("div", { style: { fontSize: "14px", fontWeight: "600" } }, [t._v(label)]),
            sub ? h("div", { style: { fontSize: "12px", color: C.se, marginTop: "2px" } }, [t._v(sub)]) : null
          ]),
          h("gl-switch", { attrs: { size: "small", value: value, disabled: t.busy }, on: { change: handler } })
        ]);
      }
      var controlsCard = card([
        toggleRow("VPN", t.tunneled ? "Tunnel active" : (t.vpnOn ? "Running — no server (direct)" : "Tunnel stopped"), t.vpnOn, function (v) { t.toggleVpn(v); }),
        h("div", { style: { height: "1px", background: C.line, margin: "12px 0" } }),
        toggleRow("Kill switch", "Block LAN if the tunnel drops", t.ksOn, function (v) { t.toggleKs(v); })
      ]);

      // ======================================================================
      // 3) ADD SERVERS button + inline panel
      // ======================================================================
      var addButton = pillBtn("＋ Add servers", null, { onClick: function () { t.toggleAdd(); } });
      var addPanel = t.showAdd ? h("div", { style: { background: "#fff", borderRadius: "14px", boxShadow: "0 1px 3px rgba(20,30,60,.06)", margin: "-4px 0 13px", padding: "14px" } }, [
        h("el-input", { staticClass: "r-in", attrs: { value: t.addLink, type: "textarea", rows: 3, placeholder: "vless:// or hysteria2://, one per line, or a subscription URL", size: "small" }, on: { input: function (v) { t.addLink = v; } } }),
        h("el-input", { staticClass: "r-in", style: { marginTop: "8px" }, attrs: { value: t.addName, placeholder: "Name (optional)", size: "small" }, on: { input: function (v) { t.addName = v; } } }),
        h("div", { style: { display: "flex", gap: "8px", marginTop: "9px", alignItems: "center" } }, [
          h("gl-button", { staticClass: "btn-item", attrs: { type: "primary", loading: t.adding }, on: { click: function () { t.addServer(); } } }, [t._v("Add")]),
          h("gl-button", { staticClass: "btn-item", attrs: { type: "default", disabled: t.adding }, on: { click: function () { t.showAdd = false; } } }, [t._v("Cancel")]),
          t.addMsg ? h("span", { style: { marginLeft: "4px", color: (t.addOk ? C.gr : C.red), fontSize: "13px" } }, [t._v(t.addMsg)]) : null
        ])
      ]) : null;

      // ======================================================================
      // 4) AUTO button (favorites pool) — RED when active
      // ======================================================================
      var favCount = (t.servers || []).filter(function (x) { return x.fav; }).length;
      var autoActive = isAutoMode(s.mode);
      var autoButton = pillBtn("⟳ Auto", favCount + " in pool", { active: autoActive, onClick: function () { t.goAuto(); } });

      // ======================================================================
      // 5) FILTER card (country chips + protocol chips)
      // ======================================================================
      var counts = {};
      (t.servers || []).forEach(function (sv) { var c = detectCC(sv.tag) || "?"; counts[c] = (counts[c] || 0) + 1; });
      var ccKeys = Object.keys(counts).sort();
      var allOn = ccKeys.length > 0 && ccKeys.every(function (k) { return t.ccSel[k]; });
      var ccChips = [chip([t._v("All")], allOn, function () { t.selectAllCC(ccKeys, allOn); })];
      ccKeys.forEach(function (k) {
        var on = !!t.ccSel[k];
        ccChips.push(chip([
          t._v((k === "?" ? "🏳️" : isoFlag(k)) + " " + k),
          h("span", { style: { color: on ? "rgba(255,255,255,.8)" : C.se, marginLeft: "5px", fontSize: "12px" } }, [t._v(String(counts[k]))])
        ], on, function () { t.toggleCC(k); }));
      });
      var PR = [["all", "All"], ["reality", "🔒 Reality"], ["tls", "VLESS-TLS"], ["trojan", "Trojan"], ["shadowsocks", "Shadowsocks"], ["hysteria2", "⚡ Hysteria2"]];
      var prChips = PR.map(function (o) {
        return chip([t._v(o[1])], t.prSel === o[0], function () { t.setPr(o[0]); });
      });
      var filterCard = card([
        ctitle("Country"),
        h("div", { style: { display: "flex", flexWrap: "wrap", gap: "7px" } }, ccChips),
        h("div", { style: { fontSize: "13px", fontWeight: "700", color: "#3a3f4b", margin: "14px 0 12px" } }, [t._v("Protocol")]),
        h("div", { style: { display: "flex", flexWrap: "wrap", gap: "7px" } }, prChips)
      ]);

      // ======================================================================
      // 6) SERVERS card
      // ======================================================================
      var shown = (t.servers || []).filter(function (sv) {
        var c = detectCC(sv.tag) || "?";
        if (!t.ccSel[c]) return false;
        if (t.prSel !== "all" && famOf(sv) !== t.prSel) return false;
        return true;
      });
      function srvActive(tag) { return s.mode === tag || (isAutoMode(s.mode) && s.active === tag); }

      var rows;
      if (!t.serversLoaded) rows = [h("div", { style: { fontSize: "13px", color: C.se, padding: "10px 0" } }, [t._v("Loading…")])];
      else if (!t.servers.length) rows = [h("div", { style: { fontSize: "13px", color: C.se, padding: "10px 0" } }, [t._v("No servers yet. Add some above.")])];
      else if (!shown.length) rows = [h("div", { style: { fontSize: "13px", color: C.se, padding: "10px 0" } }, [t._v("No servers match the filter.")])];
      else {
        rows = shown.map(function (sv, idx) {
          var cc = detectCC(sv.tag) || "?";
          var fl = (cc === "?" ? "🏳️" : isoFlag(cc));
          var name = (sv.tag || "").replace(/^srv-/, "");
          var pv = t.pings[sv.tag];
          var pingTxt = (pv === undefined || pv === null) ? (t.pinging ? "…" : "—") : (pv < 0 ? "timeout" : (pv + " ms"));
          var pingClr = (pv === undefined || pv === null) ? C.se : pingColor(pv);
          var isPick = (s.mode === sv.tag);
          var nowTag = srvActive(sv.tag);
          var last = (idx === shown.length - 1);
          return h("div", {
            style: Object.assign({
              display: "flex", alignItems: "center", gap: "11px", padding: "11px 2px", cursor: "pointer",
              borderBottom: last ? "none" : "1px solid " + C.line
            }, isPick ? { background: C.bluebg, margin: "0 -8px", padding: "11px 10px", borderRadius: "9px", borderBottom: "none" } : {}),
            on: { click: function () { if (!t.busy && s.mode !== sv.tag) t.setProto(sv.tag); } }
          }, [
            h("span", {
              style: { fontSize: "20px", lineHeight: "1", width: "21px", textAlign: "center", color: sv.fav ? "#f0a500" : "#cdd2da" },
              on: { click: function (e) { e.stopPropagation(); if (!t.busy) t.setFav(sv); } }
            }, [t._v(sv.fav ? "★" : "☆")]),
            h("div", { style: { flex: "1", minWidth: "0" } }, [
              h("div", { style: { fontSize: "14px", fontWeight: "600", display: "flex", alignItems: "center", gap: "6px" } }, [
                t._v(fl + " " + name),
                nowTag ? h("span", { style: { color: C.blue, fontWeight: "800", fontSize: "11px" } }, [t._v("● now")]) : null
              ]),
              h("div", { style: { fontSize: "11.5px", color: C.se, marginTop: "2px" } }, [t._v(famLabel(famOf(sv)) + " · " + (sv.server || ""))])
            ]),
            h("span", { style: { fontSize: "13px", fontWeight: "800", whiteSpace: "nowrap", color: pingClr } }, [t._v(pingTxt)]),
            // quiet trailing delete: small grey ✕; first tap arms -> "Удалить?",
            // second tap confirms. stopPropagation so the row body still connects.
            (t.delTag === sv.tag)
              ? h("span", {
                  style: { fontSize: "12px", fontWeight: "700", color: C.red, whiteSpace: "nowrap", cursor: "pointer", padding: "2px 4px", userSelect: "none" },
                  on: { click: function (e) { e.stopPropagation(); if (!t.busy) t.armDel(sv.tag); } }
                }, [t._v("Delete?")])
              : h("span", {
                  style: { fontSize: "15px", lineHeight: "1", color: "#c4c8d2", cursor: "pointer", padding: "2px 4px", userSelect: "none" },
                  on: { click: function (e) { e.stopPropagation(); if (!t.busy) t.armDel(sv.tag); } }
                }, [t._v("✕")])
          ]);
        });
      }

      var bulkRow = (t.servers && t.servers.length && shown.length) ? h("div", { style: { display: "flex", flexWrap: "wrap", gap: "8px", marginTop: "12px" } }, [
        h("gl-button", { staticClass: "btn-item", attrs: { type: "default", disabled: t.busy }, on: { click: function () { t.setFavBulk(shown.map(function (x) { return x.tag; }), 1); } } }, [t._v("★ all shown")]),
        h("gl-button", { staticClass: "btn-item", attrs: { type: "default", disabled: t.busy }, on: { click: function () { t.setFavBulk(shown.map(function (x) { return x.tag; }), 0); } } }, [t._v("Clear ★")]),
        h("gl-button", { staticClass: "btn-item", attrs: { loading: t.pinging }, on: { click: function () { t.pingServers(); } } }, [t._v("Ping")])
      ]) : null;

      var serversCard = card([
        ctitle("Servers", (t.servers && t.servers.length) ? ("showing " + shown.length + " of " + t.servers.length) : null),
        h("div", {}, rows),
        bulkRow
      ]);

      // ======================================================================
      // PRESERVED: subscriptions / speedtest / version
      // ======================================================================
      function sectionTitle(txt) { return h("div", { style: { fontWeight: "700", fontSize: "13px", color: "#3a3f4b", margin: "0 0 12px" } }, [t._v(txt)]); }
      function kv(label, value) {
        return h("div", { style: { display: "flex", justifyContent: "space-between", alignItems: "center", padding: "9px 0", borderBottom: "1px solid " + C.line, fontSize: "14px" } }, [
          h("span", { style: { color: C.se } }, [t._v(label)]),
          h("span", { style: { fontWeight: "600", wordBreak: "break-all", textAlign: "right" } }, [t._v(value == null || value === "" ? "—" : value)])
        ]);
      }

      var subRows;
      if (!t.subsLoaded) subRows = [h("div", { style: { color: C.se, fontSize: "13px", padding: "6px 0" } }, [t._v("Loading…")])];
      else if (!t.subs.length) subRows = [h("div", { style: { color: C.se, fontSize: "13px", padding: "6px 0" } }, [t._v("No subscriptions yet. Add one below.")])];
      else subRows = t.subs.map(function (sb) {
        var meta = [];
        if (sb.used || sb.total) meta.push("↓ " + t.fmtBytes(sb.used) + (sb.total ? (" / " + t.fmtBytes(sb.total)) : " / ∞"));
        if (sb.expire) meta.push("until " + t.fmtDate(sb.expire));
        var line2 = (sb.count || 0) + " servers · updated " + t.fmtAgo(sb.updated);
        var kids = [
          h("div", { style: { fontSize: "14px", fontWeight: "500", wordBreak: "break-all" } }, [t._v(sb.name || sb.id)]),
          h("div", { style: { fontSize: "12px", color: C.se } }, [t._v(line2)])
        ];
        if (meta.length) kids.push(h("div", { style: { fontSize: "12px", color: C.se } }, [t._v(meta.join(" · "))]));
        return h("div", { style: { display: "flex", justifyContent: "space-between", alignItems: "center", padding: "10px 0", borderBottom: "1px solid " + C.line } }, [
          h("div", { style: { minWidth: "0" } }, kids),
          h("gl-button", { staticClass: "btn-item", attrs: { type: "abort", disabled: t.subBusy }, on: { click: function () { t.delSub(sb.id); } } }, [t._v("Remove")])
        ]);
      });
      var subsCard = card([
        sectionTitle("Subscriptions"),
        h("p", { style: { fontSize: "12px", color: C.se, margin: "0 0 10px" } }, [t._v("Paste a subscription link (VLESS / Reality / Trojan / Shadowsocks / Hysteria2) — all its servers appear above, auto-refreshed every 6 h.")]),
        h("div", {}, subRows),
        h("div", { style: { marginTop: "12px" } }, [
          h("el-input", { staticClass: "r-in", attrs: { value: t.subUrl, placeholder: "Subscription URL (https://…)", size: "small", clearable: true }, on: { input: function (v) { t.subUrl = v; } } }),
          h("el-input", { staticClass: "r-in", style: { marginTop: "8px" }, attrs: { value: t.subName, placeholder: "Name (optional)", size: "small" }, on: { input: function (v) { t.subName = v; } } }),
          h("div", { style: { display: "flex", alignItems: "center", flexWrap: "wrap", gap: "8px", marginTop: "8px" } }, [
            h("gl-button", { staticClass: "btn-item", attrs: { type: "primary", loading: t.subBusy }, on: { click: function () { t.addSub(); } } }, [t._v("Add subscription")]),
            (t.subs && t.subs.length) ? h("gl-button", { staticClass: "btn-item", attrs: { loading: t.refreshingSubs }, on: { click: function () { t.refreshSubs(); } } }, [t._v("Update")]) : null,
            t.subMsg ? h("span", { style: { color: (t.subOk ? C.gr : C.red), fontSize: "13px" } }, [t._v(t.subMsg)]) : null
          ])
        ])
      ]);

      var spdLine = t.spd ? h("span", { style: { marginLeft: "12px", fontWeight: "600" } }, [t._v("↓ " + t.spd.down + " · ↑ " + t.spd.up + " Mbit/s")]) : null;
      var speedCard = card([
        sectionTitle("Speed test"),
        h("div", { style: { display: "flex", alignItems: "center" } }, [
          h("gl-button", { attrs: { type: "primary", loading: t.spdRunning }, on: { click: function () { t.runSpeedtest(); } } }, [t._v(t.spdRunning ? "Testing…" : "Run test")]),
          spdLine
        ])
      ]);

      var versionCard = card([
        sectionTitle("Version"),
        kv("Installed", t.ver.installed || (t.verLoaded ? "unknown" : "…")),
        kv("Latest", t.ver.latest || (t.verLoaded ? "unknown" : "…")),
        h("div", { style: { marginTop: "14px", display: "flex", alignItems: "center", flexWrap: "wrap", gap: "8px" } }, [
          h("gl-button", { attrs: { loading: t.checking }, on: { click: function () { t.checkUpdate(); } } }, [t._v("Check for updates")]),
          t.ver.update ? h("gl-button", { staticClass: "btn-item", attrs: { type: "primary", loading: t.updating }, on: { click: function () { t.doUpdate(); } } }, [t._v("Update")]) : null,
          (t.verLoaded && !t.ver.update && t.ver.latest && t.ver.latest !== "unknown") ? h("span", { style: { color: C.gr, fontSize: "13px" } }, [t._v("Up to date")]) : null,
          t.updateMsg ? h("span", { style: { color: C.se, fontSize: "13px" } }, [t._v(t.updateMsg)]) : null
        ])
      ]);

      // ---- error / loading banner (kept minimal) ----
      var banner = null;
      if (!t.loaded) banner = h("div", { staticClass: "status-tips" }, [h("p", [t._v("Loading…")])]);
      else if (t.err) banner = h("div", { staticClass: "status-tips is-warning" }, [h("span", { staticClass: "iconfont icon-warning" }), h("p", [t._v("Couldn't read tunnel status.")])]);

      return h("div", { staticClass: "reality-wrapper" }, [
        banner,
        netCard,
        controlsCard,
        addButton,
        addPanel,
        autoButton,
        filterCard,
        serversCard,
        subsCard,
        speedCard,
        versionCard
      ]);
    }
  };
})()
