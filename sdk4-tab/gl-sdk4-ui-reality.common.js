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

  return {
    name: "realityview",
    data: function () {
      return {
        loaded: false, err: false, busy: false,
        st: {},                 // last get_status result
        vpnOn: false, ksOn: false, tunneled: false,
        servers: [], serversLoaded: false,
        addLink: "", addName: "", addMsg: "", addOk: false, adding: false,
        editTag: "", editLink: "", editName: "", editMsg: "", editing: false,
        spinning: false, spd: null, spdRunning: false,
        traf: { upS: 0, downS: 0, up: 0, down: 0, conns: 0, ok: false },
        ver: { installed: "", latest: "", update: false }, verLoaded: false,
        checking: false, updating: false, updateMsg: "",
        subs: [], subsLoaded: false, subUrl: "", subName: "", subMsg: "", subOk: false, subBusy: false, refreshingSubs: false,
        pings: {}, pinging: false,
        protoFilter: "all"        // All | reality | hysteria2 — filters the server list + Auto pool
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
    beforeDestroy: function () { if (this._timer) clearInterval(this._timer); if (this._trafTimer) clearInterval(this._trafTimer); },
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
        if (!/^https?:\/\//i.test(url)) { this.subOk = false; this.subMsg = "Paste a subscription URL (https://…)"; return; }
        this.subBusy = true; this.subMsg = "";
        call("add_sub", { url: url, name: (this.subName || "").trim() }).then(function (r) {
          self.subBusy = false;
          if (r && r.ok) {
            self.subUrl = ""; self.subName = ""; self.subOk = true;
            self.subMsg = "Added — " + (r.added || 0) + " servers";
            self.loadSubs(); self.loadServers();
          } else { self.subOk = false; self.subMsg = (r && r.msg) ? r.msg : "Could not add subscription"; }
        }).catch(function () { self.subBusy = false; self.subOk = false; self.subMsg = "Could not add subscription"; });
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
          } else { self.subOk = false; self.subMsg = (r && r.msg) ? r.msg : "Refresh failed"; }
        }).catch(function () { self.refreshingSubs = false; self.subOk = false; self.subMsg = "Refresh failed"; });
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
        call("set_proto", { proto: key }).then(function () {
          setTimeout(function () { self.busy = false; self.refresh(); }, 2500);
        }).catch(function () { self.busy = false; self.refresh(); });
      },
      autoTagForFilter: function () {
        return this.protoFilter === "reality" ? "auto-reality"
             : this.protoFilter === "hysteria2" ? "auto-hy2" : "auto";
      },
      setFilter: function (f) {
        this.protoFilter = f;
        // When currently on Auto, re-point it to this protocol's pool live.
        var m = this.st && this.st.mode;
        if (m === "auto" || m === "auto-reality" || m === "auto-hy2") this.setProto(this.autoTagForFilter());
      },
      addServer: function () {
        var self = this; var raw = (this.addLink || "").trim();
        if (!raw) { this.addMsg = "Paste a link, a list, or a subscription"; return; }
        // Bulk import (Shadowrocket-style): multi-line list, an http(s) subscription
        // URL, or a base64 blob -> import_links. A single scheme link -> normal add.
        var lines = raw.split(/\r?\n/).map(function (s) { return s.trim(); }).filter(Boolean);
        var isBulk = lines.length > 1 || /^https?:\/\//i.test(raw) || (lines.length === 1 && raw.indexOf("://") < 0);
        this.adding = true; this.addMsg = "";
        if (isBulk) {
          call("import_links", { text: raw }).then(function (r) {
            self.adding = false;
            if (r && r.ok && r.added > 0) {
              self.addLink = ""; self.addName = "";
              self.addOk = true;
              self.addMsg = "Added " + r.added + (r.failed ? (", skipped " + r.failed) : "");
              self.loadServers();
            } else { self.addOk = false; self.addMsg = (r && r.added === 0) ? "No valid configs found" : ((r && r.msg) ? r.msg : "Import failed"); }
          }).catch(function () { self.adding = false; self.addOk = false; self.addMsg = "Import failed"; });
          return;
        }
        call("add_server", { link: raw, name: (this.addName || "").trim() }).then(function (r) {
          self.adding = false;
          if (r && r.ok) { self.addLink = ""; self.addName = ""; self.addMsg = ""; self.loadServers(); }
          else { self.addOk = false; self.addMsg = (r && r.msg) ? r.msg : "Failed to add server"; }
        }).catch(function () { self.adding = false; self.addOk = false; self.addMsg = "Failed to add server"; });
      },
      delServer: function (tag) {
        // No window.confirm() here: GL's embedded panel webview can silently
        // suppress confirm() (returns false) -> the delete would never fire.
        var self = this; this.busy = true;
        call("del_server", { tag: tag }).then(function () {
          self.busy = false; self.cancelEdit(); self.loadServers();
        }).catch(function () { self.busy = false; self.cancelEdit(); self.loadServers(); });
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
      fmtBytes: function (n) {
        n = Number(n) || 0; if (n < 0) n = 0;
        var u = ["B", "KB", "MB", "GB", "TB"], i = 0;
        while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
        return (i === 0 ? Math.round(n) : n.toFixed(n < 10 ? 1 : 0)) + " " + u[i];
      },
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
        var self = this; this.updating = true; this.updateMsg = "Update scheduled — installing, this page will reload…";
        call("do_update").then(function (r) {
          if (r && r.msg) self.updateMsg = r.msg + " — this page will reload.";
          // the installer restarts services and this very tab; reload after ~85s to
          // pick up the new version + confirmation.
          setTimeout(function () { try { location.reload(); } catch (e) {} }, 85000);
        }).catch(function () { self.updating = false; self.updateMsg = "Update failed to start"; });
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

      // ---- toggle row helper (label + gl-switch) ----
      function toggleRow(label, sub, val, handler) {
        return h("div", { staticClass: "r-row", style: { display: "flex", justifyContent: "space-between", alignItems: "center", padding: "12px 2px", borderBottom: "1px solid rgba(0,0,0,0.06)" } }, [
          h("div", [ h("div", { style: { fontSize: "14px", fontWeight: "500" } }, [t._v(label)]), sub ? h("div", { style: { fontSize: "12px", color: "#8a8f99", marginTop: "2px" } }, [t._v(sub)]) : null ]),
          h("gl-switch", { attrs: { size: "small", value: val, disabled: t.busy }, on: { change: handler } })
        ]);
      }

      // ---- protocol filter: 3 FIXED options (All / Reality / Hysteria2) ----
      // Filters the server list + the Auto pool. NOT one button per server.
      function srvLabel(sv) {
        if (sv.type === "vless") return "Reality";
        if (sv.type === "hysteria2") return "Hysteria2";
        return (sv.tag || "").replace(/^srv-/, "") || sv.tag;
      }
      var FILTERS = [
        { key: "all",       label: "All" },
        { key: "reality",   label: "🔒 Reality" },
        { key: "hysteria2", label: "⚡ Hysteria2" }
      ];
      var filterBtns = FILTERS.map(function (p) {
        var on = (t.protoFilter === p.key);
        return h("gl-button", {
          staticClass: "btn-item",
          style: { marginRight: "8px", marginBottom: "8px" },
          attrs: { type: on ? "primary" : "default", disabled: t.busy },
          on: { click: function () { t.setFilter(p.key); } }
        }, [t._v(p.label)]);
      });
      // server filtering + active-state helpers
      var FILT_TYPE = { reality: "vless", hysteria2: "hysteria2" };
      var wantType = FILT_TYPE[t.protoFilter];
      var autoTag = t.protoFilter === "reality" ? "auto-reality" : t.protoFilter === "hysteria2" ? "auto-hy2" : "auto";
      function isAutoMode(m) { return m === "auto" || m === "auto-reality" || m === "auto-hy2"; }
      function srvActive(tag) { return s.mode === tag || (isAutoMode(s.mode) && s.active === tag); }

      // ---- servers list (filtered by protocol) + an "Auto" row; tap a server to connect ----
      var fservers = wantType ? (t.servers || []).filter(function (sv) { return sv.type === wantType; }) : (t.servers || []);
      var serverRows;
      if (!t.serversLoaded) serverRows = [h("div", { style: { color: "#8a8f99", fontSize: "13px", padding: "6px 0" } }, [t._v("Loading…")])];
      else if (!t.servers.length) serverRows = [h("div", { style: { color: "#8a8f99", fontSize: "13px", padding: "6px 0" } }, [t._v("No custom servers yet. Add one below.")])];
      else {
        serverRows = [];
        // "Auto" row — best server within the current protocol filter
        if (fservers.length) {
          var autoOn = (s.mode === autoTag);
          serverRows.push(h("div", { staticClass: "r-row", style: { display: "flex", justifyContent: "space-between", alignItems: "center", padding: "10px 2px", borderBottom: "1px solid rgba(0,0,0,0.06)", cursor: "pointer" }, on: { click: function () { if (!t.busy && s.mode !== autoTag) t.setProto(autoTag); } } }, [
            h("div", { style: { minWidth: "0" } }, [
              h("div", { style: { fontSize: "14px", fontWeight: "600", color: autoOn ? "#2f6fd8" : "#1f2733" } }, [t._v((autoOn ? "✓ " : "") + "Auto")]),
              h("div", { style: { fontSize: "12px", color: "#8a8f99" } }, [t._v("Best server automatically")])
            ]),
            autoOn ? h("span", { style: { color: "#2f6fd8", fontWeight: "700", fontSize: "15px" } }, [t._v("●")]) : null
          ]));
        } else {
          serverRows.push(h("div", { style: { color: "#8a8f99", fontSize: "13px", padding: "6px 0" } }, [t._v("No " + t.protoFilter + " servers — switch the Protocol filter above.")]));
        }
        // each (filtered) server — tap the name to connect, Edit/Delete on the right
        fservers.forEach(function (sv) {
          var isEditing = (t.editTag === sv.tag);
          var pv = t.pings[sv.tag];
          var pingTxt = (pv === undefined || pv === null) ? (t.pinging ? "…" : "—") : (pv < 0 ? "timeout" : (pv + " ms"));
          var pingClr = (pv === undefined || pv === null) ? "#8a8f99" : (pv < 0 ? "#e5534b" : (pv < 150 ? "#10b981" : (pv < 350 ? "#e0a800" : "#e5534b")));
          var dispName = (sv.tag || "").replace(/^srv-/, "");
          var on = srvActive(sv.tag);
          var headRow = h("div", { staticClass: "r-row", style: { display: "flex", justifyContent: "space-between", alignItems: "center", padding: "10px 2px", borderBottom: isEditing ? "none" : "1px solid rgba(0,0,0,0.06)" } }, [
            h("div", { style: { minWidth: "0", flex: "1", cursor: "pointer" }, on: { click: function () { if (!t.busy && s.mode !== sv.tag) t.setProto(sv.tag); } } }, [
              h("div", { style: { fontSize: "14px", fontWeight: "600", wordBreak: "break-all", color: on ? "#2f6fd8" : "#1f2733" } }, [t._v((on ? "✓ " : "") + dispName)]),
              h("div", { style: { fontSize: "12px", color: "#8a8f99" } }, [t._v((sv.type || "?") + " · " + (sv.server || ""))])
            ]),
            h("div", { style: { whiteSpace: "nowrap", display: "flex", alignItems: "center" } }, [
              h("span", { style: { fontSize: "13px", fontWeight: "600", marginRight: "10px", color: pingClr } }, [t._v(pingTxt)]),
              h("gl-button", { staticClass: "btn-item", attrs: { type: "default", disabled: t.busy || (t.editTag !== "" && !isEditing) }, on: { click: function () { isEditing ? t.cancelEdit() : t.startEdit(sv); } } }, [t._v(isEditing ? "Cancel" : "Edit")])
            ])
          ]);
          if (!isEditing) { serverRows.push(headRow); return; }
          var editBox = h("div", { style: { padding: "4px 2px 12px", borderBottom: "1px solid rgba(0,0,0,0.06)" } }, [
            h("el-input", { staticClass: "r-in", style: { marginBottom: "8px" }, attrs: { value: t.editLink, placeholder: "New vless://… or hysteria2://… link", size: "small", clearable: true }, on: { input: function (v) { t.editLink = v; } } }),
            h("el-input", { staticClass: "r-in", style: { marginBottom: "8px" }, attrs: { value: t.editName, placeholder: "Name", size: "small" }, on: { input: function (v) { t.editName = v; } } }),
            h("div", { style: { display: "flex", alignItems: "center", justifyContent: "space-between" } }, [
              h("gl-button", { staticClass: "btn-item", attrs: { type: "primary", loading: t.editing }, on: { click: function () { t.saveEdit(); } } }, [t._v("Save")]),
              h("gl-button", { staticClass: "btn-item", attrs: { type: "abort", disabled: t.busy }, on: { click: function () { t.delServer(sv.tag); } } }, [t._v("Delete")])
            ]),
            t.editMsg ? h("span", { style: { marginLeft: "10px", color: "#e5534b", fontSize: "13px" } }, [t._v(t.editMsg)]) : null
          ]);
          serverRows.push(h("div", {}, [headRow, editBox]));
        });
      }

      var addBox = h("div", { style: { marginTop: "12px" } }, [
        h("el-input", { staticClass: "r-in", style: { marginBottom: "8px" }, attrs: { value: t.addLink, type: "textarea", rows: 4, placeholder: "One link, OR many (one per line), OR a subscription URL / base64", size: "small" }, on: { input: function (v) { t.addLink = v; } } }),
        h("el-input", { staticClass: "r-in", style: { marginBottom: "8px" }, attrs: { value: t.addName, placeholder: "Name (optional)", size: "small" }, on: { input: function (v) { t.addName = v; } } }),
        h("gl-button", { staticClass: "btn-item", attrs: { type: "primary", loading: t.adding }, on: { click: function () { t.addServer(); } } }, [t._v("Add server")]),
        t.addMsg ? h("span", { style: { marginLeft: "10px", color: (t.addOk ? "#10b981" : "#e5534b"), fontSize: "13px" } }, [t._v(t.addMsg)]) : null
      ]);

      // ---- subscriptions list ----
      var subRows;
      if (!t.subsLoaded) subRows = [h("div", { style: { color: "#8a8f99", fontSize: "13px", padding: "6px 0" } }, [t._v("Loading…")])];
      else if (!t.subs.length) subRows = [h("div", { style: { color: "#8a8f99", fontSize: "13px", padding: "6px 0" } }, [t._v("No subscriptions yet. Add one below.")])];
      else subRows = t.subs.map(function (sb) {
        var meta = [];
        // traffic used / total (total 0 = unlimited) — Happ-style usage line
        if (sb.used || sb.total) {
          meta.push("↓ " + t.fmtBytes(sb.used) + (sb.total ? (" / " + t.fmtBytes(sb.total)) : " / ∞"));
        }
        if (sb.expire) meta.push("expires " + t.fmtDate(sb.expire));
        var line2 = (sb.count || 0) + " servers · updated " + t.fmtAgo(sb.updated);
        var kids = [
          h("div", { style: { fontSize: "14px", fontWeight: "500", wordBreak: "break-all" } }, [t._v(sb.name || sb.id)]),
          h("div", { style: { fontSize: "12px", color: "#8a8f99" } }, [t._v(line2)])
        ];
        if (meta.length) kids.push(h("div", { style: { fontSize: "12px", color: "#8a8f99" } }, [t._v(meta.join(" · "))]));
        if (sb.support) kids.push(h("a", { attrs: { href: sb.support, target: "_blank" }, style: { fontSize: "12px", color: "#2f6fd8" } }, [t._v("Support")]));
        return h("div", { staticClass: "r-row", style: { display: "flex", justifyContent: "space-between", alignItems: "center", padding: "10px 2px", borderBottom: "1px solid rgba(0,0,0,0.06)" } }, [
          h("div", { style: { minWidth: "0" } }, kids),
          h("div", { style: { whiteSpace: "nowrap" } }, [
            h("gl-button", { staticClass: "btn-item", attrs: { type: "abort", disabled: t.subBusy }, on: { click: function () { t.delSub(sb.id); } } }, [t._v("Remove")])
          ])
        ]);
      });

      // ---- speedtest ----
      var spdLine = t.spd ? h("span", { style: { marginLeft: "12px", fontWeight: "500" } }, [t._v("↓ " + t.spd.down + " · ↑ " + t.spd.up + " Mbps")]) : null;

      return h("div", { staticClass: "reality-wrapper" }, [
        h("gl-title", { attrs: { title: "sing-box", badge: "VPN" } }),

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
          // LIVE TRAFFIC — moving ↓/↑ numbers = proof data is really flowing through the tunnel
          (t.vpnOn ? h("div", { style: { marginTop: "12px", padding: "12px", background: (t.traf.ok ? "rgba(16,185,129,0.08)" : "rgba(0,0,0,0.04)"), borderRadius: "10px" } }, [
            h("div", { style: { fontSize: "12px", color: "#8a8f99", marginBottom: "6px" } }, [t._v("Live traffic" + (t.traf.conns ? (" · " + t.traf.conns + " active") : ""))]),
            h("div", { style: { display: "flex", justifyContent: "space-between", fontSize: "18px", fontWeight: "700" } }, [
              h("span", { style: { color: "#10b981" } }, [t._v("↓ " + t.fmtBytes(t.traf.downS) + "/s")]),
              h("span", { style: { color: "#3b82f6" } }, [t._v("↑ " + t.fmtBytes(t.traf.upS) + "/s")])
            ]),
            h("div", { style: { display: "flex", justifyContent: "space-between", fontSize: "12px", color: "#8a8f99", marginTop: "6px" } }, [
              h("span", [t._v("Total ↓ " + t.fmtBytes(t.traf.down))]),
              h("span", [t._v("↑ " + t.fmtBytes(t.traf.up))])
            ])
          ]) : null),
          toggleRow("VPN", t.tunneled ? "Tunnel active" : (t.vpnOn ? "Running — no server (direct)" : "Tunnel stopped"), t.vpnOn, function (v) { t.toggleVpn(v); }),
          toggleRow("Kill switch", "Block LAN if the tunnel drops", t.ksOn, function (v) { t.toggleKs(v); }),
          h("div", { staticClass: "btns", style: { marginTop: "14px" } }, [
            h("gl-button", { attrs: { loading: t.spinning }, on: { click: function () { t.refresh(); } } }, [t._v("Refresh")])
          ])
        ])]),

        // PROTOCOL
        h("gl-card", [ h("div", { staticClass: "main" }, [
          sectionTitle("Protocol"),
          h("div", { style: { fontSize: "12px", color: "#8a8f99", margin: "0 0 10px" } }, [t._v("Filters the server list below and which servers Auto picks among.")]),
          h("div", { style: { display: "flex", alignItems: "center", flexWrap: "wrap" } }, filterBtns),
          (isAutoMode(s.mode) && s.active) ? h("div", { style: { marginTop: "10px", fontSize: "13px", color: "#8a8f99" } }, [t._v("Auto — currently using: " + (function () { var sv = (t.servers || []).filter(function (x) { return x.tag === s.active; })[0]; return sv ? (srvLabel(sv) + " · " + (sv.tag || "").replace(/^srv-/, "")) : s.active; })())]) : null
        ])]),

        // SUBSCRIPTIONS — buy on a service, paste the link, all its servers appear (auto-updated)
        h("gl-card", [ h("div", { staticClass: "main" }, [
          sectionTitle("Subscriptions"),
          h("p", { style: { fontSize: "12px", color: "#8a8f99", margin: "0 0 10px" } }, [t._v("Buy a subscription on a VLESS/Reality service, paste its link here, and all of its servers appear below — auto-updated every 6 hours.")]),
          h("div", {}, subRows),
          h("div", { style: { marginTop: "12px" } }, [
            h("el-input", { staticClass: "r-in", style: { marginBottom: "8px" }, attrs: { value: t.subUrl, placeholder: "Subscription URL (https://…)", size: "small", clearable: true }, on: { input: function (v) { t.subUrl = v; } } }),
            h("el-input", { staticClass: "r-in", style: { marginBottom: "8px" }, attrs: { value: t.subName, placeholder: "Name (optional)", size: "small" }, on: { input: function (v) { t.subName = v; } } }),
            h("div", { style: { display: "flex", alignItems: "center", flexWrap: "wrap" } }, [
              h("gl-button", { staticClass: "btn-item", attrs: { type: "primary", loading: t.subBusy }, on: { click: function () { t.addSub(); } } }, [t._v("Add subscription")]),
              (t.subs && t.subs.length) ? h("gl-button", { staticClass: "btn-item", style: { marginLeft: "8px" }, attrs: { loading: t.refreshingSubs }, on: { click: function () { t.refreshSubs(); } } }, [t._v("Update now")]) : null,
              t.subMsg ? h("span", { style: { marginLeft: "10px", color: (t.subOk ? "#10b981" : "#e5534b"), fontSize: "13px" } }, [t._v(t.subMsg)]) : null
            ])
          ])
        ])]),

        // SERVERS
        h("gl-card", [ h("div", { staticClass: "main" }, [
          h("div", { style: { display: "flex", justifyContent: "space-between", alignItems: "center", margin: "2px 0 10px" } }, [
            h("div", { style: { fontWeight: "600", fontSize: "15px" } }, [t._v("Servers")]),
            (t.servers && t.servers.length) ? h("gl-button", { staticClass: "btn-item", attrs: { loading: t.pinging }, on: { click: function () { t.pingServers(); } } }, [t._v("Test ping")]) : null
          ]),
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
        ])]),

        // VERSION / UPDATE
        h("gl-card", [ h("div", { staticClass: "main" }, [
          sectionTitle("Version"),
          kv("Installed", t.ver.installed || (t.verLoaded ? "unknown" : "…")),
          kv("Latest", t.ver.latest || (t.verLoaded ? "unknown" : "…")),
          h("div", { staticClass: "btns", style: { marginTop: "14px", display: "flex", alignItems: "center", flexWrap: "wrap" } }, [
            h("gl-button", { attrs: { loading: t.checking }, on: { click: function () { t.checkUpdate(); } } }, [t._v("Check for updates")]),
            t.ver.update ? h("gl-button", { staticClass: "btn-item", style: { marginLeft: "8px" }, attrs: { type: "primary", loading: t.updating }, on: { click: function () { t.doUpdate(); } } }, [t._v("Update now")]) : null,
            (t.verLoaded && !t.ver.update && t.ver.latest && t.ver.latest !== "unknown") ? h("span", { style: { marginLeft: "10px", color: "#10b981", fontSize: "13px" } }, [t._v("Up to date")]) : null,
            t.updateMsg ? h("span", { style: { marginLeft: "10px", color: "#8a8f99", fontSize: "13px" } }, [t._v(t.updateMsg)]) : null
          ])
        ])])
      ]);
    }
  };
})()
