--[[--
Default level for each KOReader menu id (shared by reader and file manager,
ids are unique enough across both). Anything not listed gets level 2.

1 = Reading, 2 = Everyday, 3 = Everything.
Containers (submenus) are not listed: they show up whenever they still have
something visible inside.
]]

local R, E, A = 1, 2, 3

local levels = {
    -- Reader: navigation tab
    table_of_contents = R, bookmarks = R, toggle_bookmark = R,
    page_browser = R, go_to = R, skim_to = R,
    book_map = E, bookmark_browsing_mode = E, autoturn = E,
    go_to_previous_location = E, go_to_next_location = E,
    hide_nonlinear_flows = A,

    -- Reader: typesetting tab
    change_font = R, selection_text = R, start_content_selection = R,
    typography = E, style_tweaks = E, switch_zoom_mode = E,
    highlight_options = E, panel_zoom_options = E,
    document_settings = A, set_render_style = A, page_overlap = A,
    speed_reading_module_perception_expander = A, djvu_render_mode = A,

    -- Settings tab (both)
    frontlight = R, night_mode = R, status_bar = E, language = E,
    network_wifi = R,
    screen_rotation = R, screensaver = E, autowarmth = E,
    gesture_manager = E, gesture_overview = E,

    -- Tools
    read_timer = E, statistics = E, progress_sync = E, calibre = E,
    exporter = E, move_to_archive = E, profiles = E,
    terminal = A, text_editor = A, qrclipboard = A, wallabag = A,
    news_downloader = A, cloudstorage = A, keep_alive = A,
    doc_setting_tweak = A, synchronize_time = A, plugin_management = A,
    patch_management = A, advanced_settings = A, developer_options = A,

    -- Search
    dictionary_lookup = R, fulltext_search = R, file_search = R,
    dictionary_lookup_history = E, vocabbuilder = E, wikipedia_lookup = E,
    translate_current_page = E, file_search_results = E, opds = E,
    bookmark_search = E, fulltext_search_findall_results = A,
    wikipedia_history = A, find_book_in_calibre_catalog = A,

    -- Main tab
    history = R, open_previous_document = R, open_last_document = R,
    favorites = R, collections = R, book_status = R, book_info = R,
    bookmark_browser = E, mass_storage_actions = E, ota_update = A,
    quickstart_guide = E, version = E, about = E,
    report_bug = A, plugins_disable_external = A, system_statistics = A,

    -- File manager settings tab
    filemanager_display_mode = R, sort_by = R,
    show_filter = E, reverse_sorting = E, start_with = E,
    filebrowser_settings = A, sort_ignore_articles = A, sort_mixed = A,
}

-- Everything inside these containers is "power user" by default.
local all_inside = {
    "navi_settings", "search_settings", "document", "device", "navigation",
    "more_tools",
}

-- Always visible, whatever the tier: our own entry and the ways out.
local pinned = {
    sereno = true,
    restart_koreader = true, sleep = true, poweroff = true, reboot = true,
    start_bq = true, exit = true,
}

return {
    levels = levels,
    all_inside = all_inside,
    pinned = pinned,
}
