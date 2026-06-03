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

  var PROTOS = [
    { key: "auto",        label: "Auto" },
    { key: "hy2-out",     label: "Hysteria2" },
    { key: "reality-out", label: "Reality" }
  ];

  return {
    name: "realityview",
    data: function () {
      return {
        loaded: false, err: false, busy: false,
        st: {},                 // last get_status result
        vpnOn: false, ksOn: false, tunneled: false,
        servers: [], serversLoaded: false,
        addLink: "", addName: "", addMsg: "", adding: false,
        editTag: "", editLink: "", editName: "", editMsg: "", editing: false,
        spinning: false, spd: null, spdRunning: false
      };
    },
    created: function () {
      this.refresh();
      this.loadServers();
      var self = this;
      this._timer = setInterval(function () { if (!self.busy) self.refresh(); }, 15000);
    },
    beforeDestroy: function () { if (this._timer) clearInterval(this._timer); },
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
        }).catch(function () { self.serversLoaded = true; });
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
        call("set_proto", { proto: key }).then(function () {
          setTimeout(function () { self.busy = false; self.refresh(); }, 2500);
        }).catch(function () { self.busy = false; self.refresh(); });
      },
      addServer: function () {
        var self = this; var link = (this.addLink || "").trim();
        if (!link) { this.addMsg = "Paste a vless:// or hysteria2:// link"; return; }
        this.adding = true; this.addMsg = "";
        call("add_server", { link: link, name: (this.addName || "").trim() }).then(function (r) {
          self.adding = false;
          if (r && r.ok) { self.addLink = ""; self.addName = ""; self.addMsg = ""; self.loadServers(); }
          else { self.addMsg = (r && r.msg) ? r.msg : "Failed to add server"; }
        }).catch(function () { self.adding = false; self.addMsg = "Failed to add server"; });
      },
      delServer: function (tag) {
        var self = this; this.busy = true;
        call("del_server", { tag: tag }).then(function () { self.busy = false; self.loadServers(); })
          .catch(function () { self.busy = false; self.loadServers(); });
      },
      startEdit: function (sv) {
        this.editTag = sv.tag;
        this.editLink = "";
        this.editName = (sv.tag || "").replace(/^srv-/, "");
        this.editMsg = "";
      },
      cancelEdit: function () { this.editTag = ""; this.editLink = ""; this.editName = ""; this.editMsg = ""; },
      saveEdit: function () {
        var self = this; var link = (this.editLink || "").trim();
        if (!link) { this.editMsg = "Paste a new vless:// or hysteria2:// link"; return; }
        this.editing = true; this.editMsg = "";
        call("edit_server", { tag: this.editTag, link: link, name: (this.editName || "").trim() }).then(function (r) {
          self.editing = false;
          if (r && r.ok) { self.cancelEdit(); self.loadServers(); }
          else { self.editMsg = (r && r.msg) ? r.msg : "Failed to save"; }
        }).catch(function () { self.editing = false; self.editMsg = "Failed to save"; });
      },
      runSpeedtest: function () {
        var self = this; this.spdRunning = true; this.spd = null;
        call("speedtest").then(function (r) { self.spdRunning = false; self.spd = r || {}; })
          .catch(function () { self.spdRunning = false; self.spd = { down: "0.0", up: "0.0" }; });
      }
    },
    render: function (h) {
      var t = this, s = t.st;

      function kv(label, value, valStyle) {
        return h("div", { staticClass: "r-row", style: { display: "flex", justifyContent: "space-between", alignItems: "center", padding: "11px 2px", borderBottom: "1px solid rgba(0,0,0,0.06)", fontSize: "14px" } }, [
          h("span", { style: { color: "#8a8f99" } }, [t._v(label)]),
          h("span", { style: Object.assign({ fontWeight: "500", wordBreak: "break-all", textAlign: "right" }, valStyle || {}) }, [t._v(value == null || value === "" ? "—" : value)])
        ]);
      }
      function sectionTitle(txt) {
        return h("div", { style: { fontWeight: "600", fontSize: "15px", margin: "2px 0 10px" } }, [t._v(txt)]);
      }

      // ---- status banner ----
      var banner;
      if (!t.loaded) banner = h("div", { staticClass: "status-tips" }, [h("p", [t._v("Loading…")])]);
      else if (t.err) banner = h("div", { staticClass: "status-tips is-warning" }, [h("span", { staticClass: "iconfont icon-warning" }), h("p", [t._v("Could not read tunnel status.")])]);
      else if (t.tunneled) banner = h("div", { staticClass: "status-tips is-success" }, [h("p", [t._v("Connected — traffic is protected through the tunnel.")])]);
      else if (t.vpnOn) banner = h("div", { staticClass: "status-tips is-warning" }, [h("span", { staticClass: "iconfont icon-warning" }), h("p", [t._v("sing-box is running but no server is selected — traffic is NOT tunneled (routing direct).")])]);
      else banner = h("div", { staticClass: "status-tips is-warning" }, [h("span", { staticClass: "iconfont icon-warning" }), h("p", [t._v("Disconnected — traffic is not tunneled.")])]);

      var loc = [s.city, s.country].filter(Boolean).join(", ");
      var pingTxt = s.ping ? (s.ping + " ms") : "";
      var pingColor = !s.ping ? {} : { color: (Number(s.ping) < 150 ? "#10b981" : (Number(s.ping) < 350 ? "#e0a800" : "#e5534b")) };
      var activeProto = s.mode === "auto" ? "auto" : s.mode;

      // ---- toggle row helper (label + gl-switch) ----
      function toggleRow(label, sub, val, handler) {
        return h("div", { staticClass: "r-row", style: { display: "flex", justifyContent: "space-between", alignItems: "center", padding: "12px 2px", borderBottom: "1px solid rgba(0,0,0,0.06)" } }, [
          h("div", [ h("div", { style: { fontSize: "14px", fontWeight: "500" } }, [t._v(label)]), sub ? h("div", { style: { fontSize: "12px", color: "#8a8f99", marginTop: "2px" } }, [t._v(sub)]) : null ]),
          h("gl-switch", { attrs: { size: "small", value: val, disabled: t.busy }, on: { change: handler } })
        ]);
      }

      // ---- protocol segmented control (dynamic: Auto + one per server in the list) ----
      function srvLabel(sv) {
        if (sv.type === "vless") return "Reality";
        if (sv.type === "hysteria2") return "Hysteria2";
        return (sv.tag || "").replace(/^srv-/, "") || sv.tag;
      }
      var protoItems = [{ key: "auto", label: "Auto" }].concat(
        (t.servers || []).map(function (sv) { return { key: sv.tag, label: srvLabel(sv) }; })
      );
      var protoBtns = protoItems.map(function (p) {
        var isActive = (s.mode === p.key);
        return h("gl-button", {
          staticClass: "btn-item",
          style: { marginRight: "8px", marginBottom: "8px" },
          attrs: { type: isActive ? "primary" : "default", disabled: t.busy },
          on: { click: function () { t.setProto(p.key); } }
        }, [t._v(p.label)]);
      });

      // ---- servers list ----
      var serverRows;
      if (!t.serversLoaded) serverRows = [h("div", { style: { color: "#8a8f99", fontSize: "13px", padding: "6px 0" } }, [t._v("Loading…")])];
      else if (!t.servers.length) serverRows = [h("div", { style: { color: "#8a8f99", fontSize: "13px", padding: "6px 0" } }, [t._v("No custom servers yet. Add one below.")])];
      else serverRows = t.servers.map(function (sv) {
        var isEditing = (t.editTag === sv.tag);
        var headRow = h("div", { staticClass: "r-row", style: { display: "flex", justifyContent: "space-between", alignItems: "center", padding: "10px 2px", borderBottom: isEditing ? "none" : "1px solid rgba(0,0,0,0.06)" } }, [
          h("div", [ h("div", { style: { fontSize: "14px", fontWeight: "500" } }, [t._v(sv.tag)]), h("div", { style: { fontSize: "12px", color: "#8a8f99" } }, [t._v((sv.type || "?") + " · " + (sv.server || ""))]) ]),
          h("div", { style: { whiteSpace: "nowrap" } }, [
            h("gl-button", { staticClass: "btn-item", attrs: { type: "default", disabled: t.busy || (t.editTag !== "" && !isEditing) }, on: { click: function () { isEditing ? t.cancelEdit() : t.startEdit(sv); } } }, [t._v(isEditing ? "Cancel" : "Edit")])
          ])
        ]);
        if (!isEditing) return headRow;
        var editBox = h("div", { style: { padding: "4px 2px 12px", borderBottom: "1px solid rgba(0,0,0,0.06)" } }, [
          h("el-input", { staticClass: "r-in", style: { marginBottom: "8px" }, attrs: { value: t.editLink, placeholder: "New vless://… or hysteria2://… link", size: "small", clearable: true }, on: { input: function (v) { t.editLink = v; } } }),
          h("el-input", { staticClass: "r-in", style: { marginBottom: "8px" }, attrs: { value: t.editName, placeholder: "Name", size: "small" }, on: { input: function (v) { t.editName = v; } } }),
          h("div", { style: { display: "flex", alignItems: "center", justifyContent: "space-between" } }, [
            h("gl-button", { staticClass: "btn-item", attrs: { type: "primary", loading: t.editing }, on: { click: function () { t.saveEdit(); } } }, [t._v("Save")]),
            h("gl-button", { staticClass: "btn-item", attrs: { type: "abort", disabled: t.busy }, on: { click: function () { t.delServer(sv.tag); } } }, [t._v("Delete")])
          ]),
          t.editMsg ? h("span", { style: { marginLeft: "10px", color: "#e5534b", fontSize: "13px" } }, [t._v(t.editMsg)]) : null
        ]);
        return h("div", {}, [headRow, editBox]);
      });

      var addBox = h("div", { style: { marginTop: "12px" } }, [
        h("el-input", { staticClass: "r-in", style: { marginBottom: "8px" }, attrs: { value: t.addLink, placeholder: "vless://…  or  hysteria2://…", size: "small", clearable: true }, on: { input: function (v) { t.addLink = v; } } }),
        h("el-input", { staticClass: "r-in", style: { marginBottom: "8px" }, attrs: { value: t.addName, placeholder: "Name (optional)", size: "small" }, on: { input: function (v) { t.addName = v; } } }),
        h("gl-button", { staticClass: "btn-item", attrs: { type: "primary", loading: t.adding }, on: { click: function () { t.addServer(); } } }, [t._v("Add server")]),
        t.addMsg ? h("span", { style: { marginLeft: "10px", color: "#e5534b", fontSize: "13px" } }, [t._v(t.addMsg)]) : null
      ]);

      // ---- speedtest ----
      var spdLine = t.spd ? h("span", { style: { marginLeft: "12px", fontWeight: "500" } }, [t._v("↓ " + t.spd.down + " · ↑ " + t.spd.up + " Mbps")]) : null;

      return h("div", { staticClass: "reality-wrapper" }, [
        h("gl-title", { attrs: { title: "Reality", badge: "VPN" } }),

        // STATUS
        h("gl-card", [ h("div", { staticClass: "main" }, [
          h("div", { staticClass: "desc" }, [
            h("span", { staticClass: "iconfont icon-info" }),
            h("p", [t._v("All router and LAN traffic is routed through a self-hosted sing-box VLESS + Reality / Hysteria2 tunnel to your own server. DPI-resistant, outside GL's built-in VPN manager.")])
          ]),
          banner,
          h("div", { style: { marginTop: "14px" } }, [
            kv("Egress IP", s.egress),
            kv("Location", loc),
            kv("Ping", pingTxt, pingColor),
            kv("Server", s.server),
            kv("Protocol", s.protocol)
          ]),
          toggleRow("VPN", t.tunneled ? "Tunnel active" : (t.vpnOn ? "Running — no server (direct)" : "Tunnel stopped"), t.vpnOn, function (v) { t.toggleVpn(v); }),
          toggleRow("Kill switch", "Block LAN if the tunnel drops", t.ksOn, function (v) { t.toggleKs(v); }),
          h("div", { staticClass: "btns", style: { marginTop: "14px" } }, [
            h("gl-button", { attrs: { loading: t.spinning }, on: { click: function () { t.refresh(); } } }, [t._v("Refresh")])
          ])
        ])]),

        // PROTOCOL
        h("gl-card", [ h("div", { staticClass: "main" }, [
          sectionTitle("Protocol"),
          h("div", { style: { display: "flex", alignItems: "center", flexWrap: "wrap" } }, protoBtns),
          (s.mode === "auto" && s.active) ? h("div", { style: { marginTop: "10px", fontSize: "13px", color: "#8a8f99" } }, [t._v("Auto — currently using: " + (function () { var sv = (t.servers || []).filter(function (x) { return x.tag === s.active; })[0]; return sv ? srvLabel(sv) : s.active; })())]) : null
        ])]),

        // SERVERS
        h("gl-card", [ h("div", { staticClass: "main" }, [
          sectionTitle("Servers"),
          h("div", {}, serverRows),
          addBox
        ])]),

        // SPEEDTEST
        h("gl-card", [ h("div", { staticClass: "main" }, [
          sectionTitle("Speed test"),
          h("div", { style: { display: "flex", alignItems: "center" } }, [
            h("gl-button", { attrs: { type: "primary", loading: t.spdRunning }, on: { click: function () { t.runSpeedtest(); } } }, [t._v(t.spdRunning ? "Testing…" : "Run speed test")]),
            spdLine
          ])
        ])])
      ]);
    }
  };
})()
