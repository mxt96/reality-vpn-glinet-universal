-- Arg validator for the `reality` rpc object.
-- `true` per method => skip the default char-class validation (share-links contain ?&=@# etc.).
return {
    get_status = true,
    set_proto = true,
    set_enabled = true,
    set_killswitch = true,
    list_servers = true,
    add_server = true,
    edit_server = true,
    del_server = true,
    speedtest = true,
    check_update = true,
    do_update = true,
}