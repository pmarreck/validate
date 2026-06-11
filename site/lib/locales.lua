-- The canonical 50-locale registry for the validate.pics site.
-- Mirrors the app's catalog set (src/core/i18n/*.zig); test_locales.lua
-- cross-checks this list against those files on disk so the two can't drift.
-- slug = URL path segment ("" for en, which lives at the site root and is
-- the hreflang x-default). hreflang = BCP-47. rtl = right-to-left script.

local function L(code, slug, hreflang, native, rtl)
	return { code = code, slug = slug, hreflang = hreflang, native = native, rtl = rtl or false }
end

local list = {
	L("am", "am", "am", "አማርኛ"),
	L("ar", "ar", "ar", "العربية", true),
	L("az", "az", "az", "Azərbaycanca"),
	L("bg", "bg", "bg", "Български"),
	L("bn", "bn", "bn", "বাংলা"),
	L("bs", "bs", "bs", "Bosanski"),
	L("da", "da", "da", "Dansk"),
	L("de", "de", "de", "Deutsch"),
	L("el", "el", "el", "Ελληνικά"),
	L("en", "", "en", "English"),
	L("es", "es", "es", "Español"),
	L("fa", "fa", "fa", "فارسی", true),
	L("fi", "fi", "fi", "Suomi"),
	L("fil", "fil", "fil", "Filipino"),
	L("fr", "fr", "fr", "Français"),
	L("ha", "ha", "ha", "Hausa"),
	L("he", "he", "he", "עברית", true),
	L("hi", "hi", "hi", "हिन्दी"),
	L("hr", "hr", "hr", "Hrvatski"),
	L("hu", "hu", "hu", "Magyar"),
	L("id", "id", "id", "Bahasa Indonesia"),
	L("ig", "ig", "ig", "Igbo"),
	L("is", "is", "is", "Íslenska"),
	L("it", "it", "it", "Italiano"),
	L("ja", "ja", "ja", "日本語"),
	L("km", "km", "km", "ខ្មែរ"),
	L("ko", "ko", "ko", "한국어"),
	L("mk", "mk", "mk", "Македонски"),
	L("nb", "nb", "nb", "Norsk bokmål"),
	L("nl", "nl", "nl", "Nederlands"),
	L("pa", "pa", "pa", "ਪੰਜਾਬੀ"),
	L("pl", "pl", "pl", "Polski"),
	L("ps", "ps", "ps", "پښتو", true),
	L("pt_br", "pt-br", "pt-BR", "Português (Brasil)"),
	L("ro", "ro", "ro", "Română"),
	L("ru", "ru", "ru", "Русский"),
	L("sl", "sl", "sl", "Slovenščina"),
	L("sq", "sq", "sq", "Shqip"),
	L("sr", "sr", "sr", "Српски"),
	L("sv", "sv", "sv", "Svenska"),
	L("sw", "sw", "sw", "Kiswahili"),
	L("ta", "ta", "ta", "தமிழ்"),
	L("th", "th", "th", "ไทย"),
	L("tr", "tr", "tr", "Türkçe"),
	L("uk", "uk", "uk", "Українська"),
	L("ur", "ur", "ur", "اردو", true),
	L("vi", "vi", "vi", "Tiếng Việt"),
	L("yo", "yo", "yo", "Yorùbá"),
	L("zh_hans", "zh-hans", "zh-Hans", "简体中文"),
	L("zh_hant", "zh-hant", "zh-Hant", "繁體中文"),
}

local by_code = {}
for _, l in ipairs(list) do by_code[l.code] = l end

return { list = list, by_code = by_code }
