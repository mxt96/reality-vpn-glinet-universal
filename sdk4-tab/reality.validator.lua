-- Arg validator for the `reality` rpc object.
-- `true` per method => skip the default char-class validation (share-links contain ?&=@# etc.).
return {
    get_status = true,
    get_traffic = true,
    set_proto = true,
    set_enabled = true,
    set_killswitch = true,
    list_servers = true,
    set_fav = true,
    set_fav_bulk = true,
    ping_servers = true,
    add_server = true,
    import_links = true,
    list_subs = true,
    add_sub = true,
    del_sub = true,
    refresh_subs = true,
    del_server = true,
    speedtest = true,
    check_update = true,
    do_update = true,
}