--[[
    Simple Localization Helper for kokomga KOReader plugin.
--]]

local G_reader_settings = G_reader_settings

-- Default fallback translation table (Chinese zh_CN / zh_TW, English)
local translations = {
    ["zh_CN"] = {
        ["Komga Browser"] = "Komga 浏览器",
        ["Server Setup"] = "服务器设置",
        ["Server URL"] = "服务器地址",
        ["API Key"] = "API 密钥",
        ["Options"] = "选项",
        ["Custom Download Dir"] = "自定义下载目录",
        ["Sync behavior"] = "同步行为",
        ["Use Komga server progress when available"] = "当可用时使用 Komga 服务器进度",
        ["Auto-push progress every %1 pages"] = "每 %1 页自动推送进度",
        ["Download into Series Subfolders"] = "下载到系列子文件夹中",
        ["Layout Options"] = "布局选项",
        ["Default View Mode: Grid"] = "默认视图模式：网格",
        ["Default View Mode: List"] = "默认视图模式：列表",
        ["List Mode Rows (%1)"] = "列表模式行数 (%1)",
        ["Grid Mode Columns (%1)"] = "网格模式列数 (%1)",
        ["Grid Mode Rows (%1)"] = "网格模式行数 (%1)",
        ["Never update cached covers"] = "绝不更新缓存封面",
        ["Clean Cache"] = "清除缓存",
        ["Cache cleared"] = "缓存已清除",
        ["Invalid number"] = "无效的数字",
        ["Updated %1"] = "已更新 %1",
        ["Komga is not configured. Please set up connection."] = "Komga 未配置。请设置连接。",
        ["Manual Setup"] = "手动设置",
        ["Auto-Generate API Key"] = "自动生成 API 密钥",
        ["Cancel"] = "取消",
        ["Manual Server Setup"] = "手动服务器设置",
        ["Save"] = "保存",
        ["Server URL cannot be empty"] = "服务器地址不能为空",
        ["API Key cannot be empty"] = "API 密钥不能为空",
        ["Server connection saved"] = "服务器连接已保存",
        ["Username/Email"] = "用户名/电子邮箱",
        ["Password"] = "密码",
        ["Username and Password are required"] = "用户名和密码是必填的",
        ["Generating API Key. Please wait..."] = "正在生成 API 密钥。请稍候...",
        ["API Key generated successfully!"] = "API 密钥生成成功！",
        ["Generation failed: %1"] = "生成失败：%1",
        ["Auto RTL for Komga books"] = "Komga 书籍自动启用从右至左",
        ["Keep Reading"] = "继续阅读",
        ["On Deck"] = "在读队列",
        ["Recently Added Series"] = "最近添加的系列",
        ["Recently Added Books"] = "最近添加的书籍",
        ["All Series"] = "所有系列",
        ["Libraries"] = "媒体库",
        ["No recent series found"] = "未找到最近的系列",
        ["Nothing in keep reading"] = "继续阅读队列为空",
        ["Nothing on deck"] = "在读队列为空",
        ["No recent books found"] = "未找到最近的书籍",
        ["No series found"] = "未找到系列",
        ["No libraries found"] = "未找到媒体库",
        ["No series in library"] = "媒体库中没有系列",
        ["No books found"] = "未找到书籍",
        ["Filter: %1"] = "过滤：%1",
        ["Unread"] = "未读",
        ["In Progress"] = "阅读中",
        ["Completed"] = "已读完",
        ["Apply Filter"] = "应用过滤",
        ["Download '%1'?"] = "下载 '%1'?",
        ["Sync module not initialized"] = "同步模块未初始化",
        ["Searching Komga for: %1"] = "正在 Komga 中搜索：%1",
        ["Manual Match Current Book"] = "手动匹配当前书籍",
        ["Matched with: %1"] = "已匹配：%1",
        ["Failed to match: %1"] = "匹配失败：%1",
        ["Checking server progress..."] = "正在检查服务器进度...",
        ["Failed to pull progress - %1"] = "拉取进度失败 - %1",
        ["Already at server progress"] = "已是服务器进度",
        ["Jumped to Page %1"] = "已跳转至第 %1 页",
        ["Server is ahead (Page %1). Jump?"] = "服务器进度领先（第 %1 页）。是否跳转？",
        ["Server is behind (Page %1). Jump?"] = "服务器进度落后（第 %1 页）。是否跳转？",
        ["Next chapter is ready: %1"] = "下一章节已就绪：%1",
        ["Next chapter is not downloaded: %1"] = "下一章节未下载：%1",
        ["Open Next Chapter"] = "打开下一章",
        ["Download & Open"] = "下载并打开",
        ["Default Action"] = "默认操作",
        ["No Wi-Fi connection. Cannot check for the next chapter."] = "无 Wi-Fi 连接。无法检查下一章节。",
        ["No next chapter found."] = "未找到下一章节。",
        ["Unknown"] = "未知",
        ["Switch to List View"] = "切换为列表视图",
        ["Switch to Grid View"] = "切换为网格视图",
        ["List Rows"] = "列表行数",
        ["Grid Columns"] = "网格列数",
        ["Grid Rows"] = "网格行数",
        ["Filter Series"] = "过滤系列",
        ["Nothing found"] = "未找到内容",
        ["No active book open to match."] = "没有打开的活动书籍以进行匹配。",
        ["Click 'Match' first."] = "请先匹配书籍。",
        ["Downloading %1..."] = "正在下载 %1...",
        ["Saved: %1"] = "已保存：%1",
        ["Failed: %1"] = "失败：%1",
        ["New"] = "新",
        ["Done"] = "已读",
        ["Download '%1'"] = "下载 '%1'",
        ["Download remaining %1 selected books"] = "下载剩余的 %1 本选中书籍",
        ["Download %1 selected books"] = "下载 %1 本选中书籍",
        ["All selected downloads finished!"] = "所有选中下载已完成！",
        ["All %1 selected books are already downloaded"] = "所有 %1 本选中书籍均已下载",
        ["Download remaining %1 books"] = "下载剩余的 %1 本书籍",
        ["Download all %1 books in this list"] = "下载此列表中的所有 %1 本书籍",
        ["Download remaining %1 books on this page"] = "下载此页面上剩余的 %1 本书籍",
        ["Download all %1 books on this page"] = "下载此页面上的所有 %1 本书籍",
        ["All downloads finished!"] = "所有下载已完成！",
        ["All %1 books in this list are already downloaded"] = "此列表中的所有 %1 本书籍均已下载",
        ["All %1 books on this page are already downloaded"] = "此页面上的所有 %1 本书籍均已下载",
        ["Bulk Download Options"] = "批量下载选项",
        ["Generate"] = "生成",
        ["Unlink Current Book"] = "取消关联当前书籍",
        ["Select Matching Komga Book"] = "选择匹配的 Komga 书籍",
        ["Unlinked from Komga successfully."] = "成功取消关联 Komga 书籍。",
        ["No matching book found on Komga server"] = "未在 Komga 服务器上找到匹配的书籍",
        ["Prev"] = "上一页",
        ["Next"] = "下一页",
        ["No active book open to unlink."] = "没有打开的活动书籍以取消关联。"
    }
}

-- Fallbacks for Chinese variants
translations["zh_TW"] = translations["zh_CN"]
translations["zh_HK"] = translations["zh_CN"]
translations["zh"] = translations["zh_CN"]

local function translate(text)
    local lang = G_reader_settings and G_reader_settings:readSetting("language") or "en"
    local lang_table = translations[lang]
    if not lang_table then
        local base_lang = lang:match("([a-z]+)")
        lang_table = translations[base_lang] or {}
    end
    return lang_table[text] or text
end

-- Simplified template support
local function T(text, ...)
    local translated = translate(text)
    local args = {...}
    for i, v in ipairs(args) do
        translated = translated:gsub("%%" .. i, tostring(v))
    end
    return translated
end

return {
    _ = translate,
    T = T
}
