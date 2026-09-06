import Foundation
import AVFoundation

// MARK: - Kokoro 音色表（kokoro-multi-lang-v1_0，53 个音色）

enum KokoroVoices {

    struct Item: Identifiable, Hashable {
        let sid: Int32
        let id: String        // 如 zf_xiaoxiao
        let label: String     // 如 "小晓 · 中文女声"
        let group: String     // 分组名
        var key: String { id }
    }

    /// 全部音色（sid 与 voices.bin 内嵌顺序一致）
    static let all: [Item] = [
        Item(sid: 45, id: "zf_xiaobei",  label: "小贝 · 中文女声", group: "中文"),
        Item(sid: 46, id: "zf_xiaoni",   label: "小妮 · 中文女声", group: "中文"),
        Item(sid: 47, id: "zf_xiaoxiao", label: "小晓 · 中文女声", group: "中文"),
        Item(sid: 48, id: "zf_xiaoyi",   label: "小怡 · 中文女声", group: "中文"),
        Item(sid: 49, id: "zm_yunjian",  label: "云健 · 中文男声", group: "中文"),
        Item(sid: 50, id: "zm_yunxi",    label: "云溪 · 中文男声", group: "中文"),
        Item(sid: 51, id: "zm_yunxia",   label: "云霞 · 中文男声", group: "中文"),
        Item(sid: 52, id: "zm_yunyang",  label: "云扬 · 中文男声", group: "中文"),
        Item(sid: 3,  id: "af_heart",    label: "Heart · 英文女声", group: "英文（美）"),
        Item(sid: 2,  id: "af_bella",    label: "Bella · 英文女声", group: "英文（美）"),
        Item(sid: 6,  id: "af_nicole",   label: "Nicole · 英文女声", group: "英文（美）"),
        Item(sid: 16, id: "am_michael",  label: "Michael · 英文男声", group: "英文（美）"),
        Item(sid: 14, id: "am_fenrir",   label: "Fenrir · 英文男声", group: "英文（美）"),
        Item(sid: 18, id: "am_puck",     label: "Puck · 英文男声", group: "英文（美）"),
        Item(sid: 0,  id: "af_alloy",    label: "Alloy · 英文女声", group: "英文（美）"),
        Item(sid: 1,  id: "af_aoede",    label: "Aoede · 英文女声", group: "英文（美）"),
        Item(sid: 4,  id: "af_jessica",  label: "Jessica · 英文女声", group: "英文（美）"),
        Item(sid: 5,  id: "af_kore",     label: "Kore · 英文女声", group: "英文（美）"),
        Item(sid: 7,  id: "af_nova",     label: "Nova · 英文女声", group: "英文（美）"),
        Item(sid: 8,  id: "af_river",   label: "River · 英文女声", group: "英文（美）"),
        Item(sid: 9,  id: "af_sarah",    label: "Sarah · 英文女声", group: "英文（美）"),
        Item(sid: 10, id: "af_sky",     label: "Sky · 英文女声", group: "英文（美）"),
        Item(sid: 11, id: "am_adam",    label: "Adam · 英文男声", group: "英文（美）"),
        Item(sid: 12, id: "am_echo",    label: "Echo · 英文男声", group: "英文（美）"),
        Item(sid: 13, id: "am_eric",    label: "Eric · 英文男声", group: "英文（美）"),
        Item(sid: 15, id: "am_liam",    label: "Liam · 英文男声", group: "英文（美）"),
        Item(sid: 17, id: "am_onyx",    label: "Onyx · 英文男声", group: "英文（美）"),
        Item(sid: 19, id: "am_santa",   label: "Santa · 英文男声", group: "英文（美）"),
        Item(sid: 21, id: "bf_emma",     label: "Emma · 英文女声", group: "英文（英）"),
        Item(sid: 20, id: "bf_alice",    label: "Alice · 英文女声", group: "英文（英）"),
        Item(sid: 22, id: "bf_isabella", label: "Isabella · 英文女声", group: "英文（英）"),
        Item(sid: 23, id: "bf_lily",     label: "Lily · 英文女声", group: "英文（英）"),
        Item(sid: 26, id: "bm_george",  label: "George · 英文男声", group: "英文（英）"),
        Item(sid: 24, id: "bm_daniel",  label: "Daniel · 英文男声", group: "英文（英）"),
        Item(sid: 25, id: "bm_fable",   label: "Fable · 英文男声", group: "英文（英）"),
        Item(sid: 27, id: "bm_lewis",   label: "Lewis · 英文男声", group: "英文（英）"),
        Item(sid: 37, id: "jf_alpha",   label: "Alpha · 日文女声", group: "日文"),
        Item(sid: 41, id: "jm_kumo",    label: "Kumo · 日文男声", group: "日文"),
        Item(sid: 28, id: "ef_dora",    label: "Dora · 西语女声", group: "其他"),
        Item(sid: 30, id: "ff_siwis",   label: "Siwis · 法语女声", group: "其他"),
        Item(sid: 35, id: "if_sara",    label: "Sara · 意语女声", group: "其他"),
        Item(sid: 42, id: "pf_dora",    label: "Dora · 葡语女声", group: "其他"),
    ]

    static func sid(for voiceID: String) -> Int32 {
        all.first(where: { $0.id == voiceID })?.sid ?? 47 // 默认 zf_xiaoxiao
    }

    struct Group: Identifiable {
        let name: String
        let items: [Item]
        var id: String { name }
    }

    /// 按语言分组（保持 all 中的出现顺序）
    static var grouped: [Group] {
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in all {
            if buckets[item.group] == nil { order.append(item.group) }
            buckets[item.group, default: []].append(item)
        }
        return order.map { Group(name: $0, items: buckets[$0] ?? []) }
    }
}

// MARK: - 模型清单（文件名与字节数）

enum KokoroModelManifest {

    struct FileEntry {
        let path: String
        let size: Int64
    }

    /// HF 仓库（csukuangfj/kokoro-int8-multi-lang-v1_0）
    static let repoID = "csukuangfj/kokoro-int8-multi-lang-v1_0"
    /// 下载源（国内镜像优先，失败自动切换）
    static let baseURLs = [
        "https://hf-mirror.com",
        "https://huggingface.co",
    ]

    /// 大文件先下（进度体验）：模型、音色、词典、FST，再是 espeak 数据
    static let files: [FileEntry] = [
        // (path, sizeBytes) — 与 HF 仓库逐字节一致，用于校验与进度
        FileEntry(path: "date-zh.fst", size: 59154),
        FileEntry(path: "espeak-ng-data/af_dict", size: 121473),
        FileEntry(path: "espeak-ng-data/am_dict", size: 63878),
        FileEntry(path: "espeak-ng-data/an_dict", size: 6691),
        FileEntry(path: "espeak-ng-data/ar_dict", size: 478165),
        FileEntry(path: "espeak-ng-data/as_dict", size: 5005),
        FileEntry(path: "espeak-ng-data/az_dict", size: 43773),
        FileEntry(path: "espeak-ng-data/ba_dict", size: 2098),
        FileEntry(path: "espeak-ng-data/be_dict", size: 2652),
        FileEntry(path: "espeak-ng-data/bg_dict", size: 87051),
        FileEntry(path: "espeak-ng-data/bn_dict", size: 89979),
        FileEntry(path: "espeak-ng-data/bpy_dict", size: 5226),
        FileEntry(path: "espeak-ng-data/bs_dict", size: 47068),
        FileEntry(path: "espeak-ng-data/ca_dict", size: 45566),
        FileEntry(path: "espeak-ng-data/chr_dict", size: 2859),
        FileEntry(path: "espeak-ng-data/cmn_dict", size: 1566335),
        FileEntry(path: "espeak-ng-data/cs_dict", size: 49645),
        FileEntry(path: "espeak-ng-data/cv_dict", size: 1344),
        FileEntry(path: "espeak-ng-data/cy_dict", size: 43130),
        FileEntry(path: "espeak-ng-data/da_dict", size: 245287),
        FileEntry(path: "espeak-ng-data/de_dict", size: 68276),
        FileEntry(path: "espeak-ng-data/el_dict", size: 72841),
        FileEntry(path: "espeak-ng-data/en_dict", size: 166944),
        FileEntry(path: "espeak-ng-data/eo_dict", size: 4666),
        FileEntry(path: "espeak-ng-data/es_dict", size: 49252),
        FileEntry(path: "espeak-ng-data/et_dict", size: 44263),
        FileEntry(path: "espeak-ng-data/eu_dict", size: 48841),
        FileEntry(path: "espeak-ng-data/fa_dict", size: 292423),
        FileEntry(path: "espeak-ng-data/fi_dict", size: 43928),
        FileEntry(path: "espeak-ng-data/fr_dict", size: 63727),
        FileEntry(path: "espeak-ng-data/ga_dict", size: 52673),
        FileEntry(path: "espeak-ng-data/gd_dict", size: 49121),
        FileEntry(path: "espeak-ng-data/gn_dict", size: 3248),
        FileEntry(path: "espeak-ng-data/grc_dict", size: 3433),
        FileEntry(path: "espeak-ng-data/gu_dict", size: 82480),
        FileEntry(path: "espeak-ng-data/hak_dict", size: 3335),
        FileEntry(path: "espeak-ng-data/haw_dict", size: 2443),
        FileEntry(path: "espeak-ng-data/he_dict", size: 6963),
        FileEntry(path: "espeak-ng-data/hi_dict", size: 92143),
        FileEntry(path: "espeak-ng-data/hr_dict", size: 49388),
        FileEntry(path: "espeak-ng-data/ht_dict", size: 1803),
        FileEntry(path: "espeak-ng-data/hu_dict", size: 153785),
        FileEntry(path: "espeak-ng-data/hy_dict", size: 62263),
        FileEntry(path: "espeak-ng-data/ia_dict", size: 331275),
        FileEntry(path: "espeak-ng-data/id_dict", size: 43458),
        FileEntry(path: "espeak-ng-data/intonations", size: 2040),
        FileEntry(path: "espeak-ng-data/io_dict", size: 2165),
        FileEntry(path: "espeak-ng-data/is_dict", size: 44354),
        FileEntry(path: "espeak-ng-data/it_dict", size: 152889),
        FileEntry(path: "espeak-ng-data/ja_dict", size: 47652),
        FileEntry(path: "espeak-ng-data/jbo_dict", size: 2243),
        FileEntry(path: "espeak-ng-data/ka_dict", size: 87775),
        FileEntry(path: "espeak-ng-data/kk_dict", size: 1859),
        FileEntry(path: "espeak-ng-data/kl_dict", size: 2838),
        FileEntry(path: "espeak-ng-data/kn_dict", size: 87828),
        FileEntry(path: "espeak-ng-data/ko_dict", size: 47523),
        FileEntry(path: "espeak-ng-data/kok_dict", size: 6394),
        FileEntry(path: "espeak-ng-data/ku_dict", size: 2265),
        FileEntry(path: "espeak-ng-data/ky_dict", size: 64977),
        FileEntry(path: "espeak-ng-data/la_dict", size: 3806),
        FileEntry(path: "espeak-ng-data/lang/aav/vi", size: 111),
        FileEntry(path: "espeak-ng-data/lang/aav/vi-VN-x-central", size: 143),
        FileEntry(path: "espeak-ng-data/lang/aav/vi-VN-x-south", size: 142),
        FileEntry(path: "espeak-ng-data/lang/art/eo", size: 41),
        FileEntry(path: "espeak-ng-data/lang/art/ia", size: 29),
        FileEntry(path: "espeak-ng-data/lang/art/io", size: 50),
        FileEntry(path: "espeak-ng-data/lang/art/jbo", size: 69),
        FileEntry(path: "espeak-ng-data/lang/art/lfn", size: 135),
        FileEntry(path: "espeak-ng-data/lang/art/piqd", size: 56),
        FileEntry(path: "espeak-ng-data/lang/art/py", size: 140),
        FileEntry(path: "espeak-ng-data/lang/art/qdb", size: 57),
        FileEntry(path: "espeak-ng-data/lang/art/qya", size: 173),
        FileEntry(path: "espeak-ng-data/lang/art/sjn", size: 175),
        FileEntry(path: "espeak-ng-data/lang/azc/nci", size: 114),
        FileEntry(path: "espeak-ng-data/lang/bat/lt", size: 28),
        FileEntry(path: "espeak-ng-data/lang/bat/ltg", size: 312),
        FileEntry(path: "espeak-ng-data/lang/bat/lv", size: 229),
        FileEntry(path: "espeak-ng-data/lang/bnt/sw", size: 41),
        FileEntry(path: "espeak-ng-data/lang/bnt/tn", size: 42),
        FileEntry(path: "espeak-ng-data/lang/ccs/ka", size: 124),
        FileEntry(path: "espeak-ng-data/lang/cel/cy", size: 37),
        FileEntry(path: "espeak-ng-data/lang/cel/ga", size: 66),
        FileEntry(path: "espeak-ng-data/lang/cel/gd", size: 51),
        FileEntry(path: "espeak-ng-data/lang/cus/om", size: 39),
        FileEntry(path: "espeak-ng-data/lang/dra/kn", size: 55),
        FileEntry(path: "espeak-ng-data/lang/dra/ml", size: 57),
        FileEntry(path: "espeak-ng-data/lang/dra/ta", size: 51),
        FileEntry(path: "espeak-ng-data/lang/dra/te", size: 70),
        FileEntry(path: "espeak-ng-data/lang/esx/kl", size: 30),
        FileEntry(path: "espeak-ng-data/lang/eu", size: 54),
        FileEntry(path: "espeak-ng-data/lang/gmq/da", size: 43),
        FileEntry(path: "espeak-ng-data/lang/gmq/is", size: 27),
        FileEntry(path: "espeak-ng-data/lang/gmq/nb", size: 87),
        FileEntry(path: "espeak-ng-data/lang/gmq/sv", size: 25),
        FileEntry(path: "espeak-ng-data/lang/gmw/af", size: 123),
        FileEntry(path: "espeak-ng-data/lang/gmw/de", size: 42),
        FileEntry(path: "espeak-ng-data/lang/gmw/en", size: 140),
        FileEntry(path: "espeak-ng-data/lang/gmw/en-029", size: 335),
        FileEntry(path: "espeak-ng-data/lang/gmw/en-GB-scotland", size: 295),
        FileEntry(path: "espeak-ng-data/lang/gmw/en-GB-x-gbclan", size: 238),
        FileEntry(path: "espeak-ng-data/lang/gmw/en-GB-x-gbcwmd", size: 188),
        FileEntry(path: "espeak-ng-data/lang/gmw/en-GB-x-rp", size: 249),
        FileEntry(path: "espeak-ng-data/lang/gmw/en-US", size: 257),
        FileEntry(path: "espeak-ng-data/lang/gmw/en-US-nyc", size: 271),
        FileEntry(path: "espeak-ng-data/lang/gmw/lb", size: 31),
        FileEntry(path: "espeak-ng-data/lang/gmw/nl", size: 23),
        FileEntry(path: "espeak-ng-data/lang/grk/el", size: 23),
        FileEntry(path: "espeak-ng-data/lang/grk/grc", size: 99),
        FileEntry(path: "espeak-ng-data/lang/inc/as", size: 42),
        FileEntry(path: "espeak-ng-data/lang/inc/bn", size: 25),
        FileEntry(path: "espeak-ng-data/lang/inc/bpy", size: 39),
        FileEntry(path: "espeak-ng-data/lang/inc/gu", size: 42),
        FileEntry(path: "espeak-ng-data/lang/inc/hi", size: 23),
        FileEntry(path: "espeak-ng-data/lang/inc/kok", size: 26),
        FileEntry(path: "espeak-ng-data/lang/inc/mr", size: 41),
        FileEntry(path: "espeak-ng-data/lang/inc/ne", size: 37),
        FileEntry(path: "espeak-ng-data/lang/inc/or", size: 39),
        FileEntry(path: "espeak-ng-data/lang/inc/pa", size: 25),
        FileEntry(path: "espeak-ng-data/lang/inc/sd", size: 66),
        FileEntry(path: "espeak-ng-data/lang/inc/si", size: 55),
        FileEntry(path: "espeak-ng-data/lang/inc/ur", size: 94),
        FileEntry(path: "espeak-ng-data/lang/ine/hy", size: 61),
        FileEntry(path: "espeak-ng-data/lang/ine/hyw", size: 365),
        FileEntry(path: "espeak-ng-data/lang/ine/sq", size: 103),
        FileEntry(path: "espeak-ng-data/lang/ira/fa", size: 90),
        FileEntry(path: "espeak-ng-data/lang/ira/fa-Latn", size: 269),
        FileEntry(path: "espeak-ng-data/lang/ira/ku", size: 40),
        FileEntry(path: "espeak-ng-data/lang/iro/chr", size: 569),
        FileEntry(path: "espeak-ng-data/lang/itc/la", size: 297),
        FileEntry(path: "espeak-ng-data/lang/jpx/ja", size: 52),
        FileEntry(path: "espeak-ng-data/lang/ko", size: 51),
        FileEntry(path: "espeak-ng-data/lang/map/haw", size: 42),
        FileEntry(path: "espeak-ng-data/lang/miz/mto", size: 183),
        FileEntry(path: "espeak-ng-data/lang/myn/quc", size: 210),
        FileEntry(path: "espeak-ng-data/lang/poz/id", size: 134),
        FileEntry(path: "espeak-ng-data/lang/poz/mi", size: 367),
        FileEntry(path: "espeak-ng-data/lang/poz/ms", size: 430),
        FileEntry(path: "espeak-ng-data/lang/qu", size: 88),
        FileEntry(path: "espeak-ng-data/lang/roa/an", size: 27),
        FileEntry(path: "espeak-ng-data/lang/roa/ca", size: 25),
        FileEntry(path: "espeak-ng-data/lang/roa/es", size: 63),
        FileEntry(path: "espeak-ng-data/lang/roa/es-419", size: 167),
        FileEntry(path: "espeak-ng-data/lang/roa/fr", size: 79),
        FileEntry(path: "espeak-ng-data/lang/roa/fr-BE", size: 84),
        FileEntry(path: "espeak-ng-data/lang/roa/fr-CH", size: 86),
        FileEntry(path: "espeak-ng-data/lang/roa/ht", size: 140),
        FileEntry(path: "espeak-ng-data/lang/roa/it", size: 109),
        FileEntry(path: "espeak-ng-data/lang/roa/pap", size: 62),
        FileEntry(path: "espeak-ng-data/lang/roa/pt", size: 95),
        FileEntry(path: "espeak-ng-data/lang/roa/pt-BR", size: 109),
        FileEntry(path: "espeak-ng-data/lang/roa/ro", size: 26),
        FileEntry(path: "espeak-ng-data/lang/sai/gn", size: 47),
        FileEntry(path: "espeak-ng-data/lang/sem/am", size: 41),
        FileEntry(path: "espeak-ng-data/lang/sem/ar", size: 50),
        FileEntry(path: "espeak-ng-data/lang/sem/he", size: 40),
        FileEntry(path: "espeak-ng-data/lang/sem/mt", size: 41),
        FileEntry(path: "espeak-ng-data/lang/sit/cmn", size: 686),
        FileEntry(path: "espeak-ng-data/lang/sit/cmn-Latn-pinyin", size: 161),
        FileEntry(path: "espeak-ng-data/lang/sit/hak", size: 128),
        FileEntry(path: "espeak-ng-data/lang/sit/my", size: 56),
        FileEntry(path: "espeak-ng-data/lang/sit/yue", size: 194),
        FileEntry(path: "espeak-ng-data/lang/sit/yue-Latn-jyutping", size: 213),
        FileEntry(path: "espeak-ng-data/lang/tai/shn", size: 92),
        FileEntry(path: "espeak-ng-data/lang/tai/th", size: 37),
        FileEntry(path: "espeak-ng-data/lang/trk/az", size: 45),
        FileEntry(path: "espeak-ng-data/lang/trk/ba", size: 25),
        FileEntry(path: "espeak-ng-data/lang/trk/cv", size: 40),
        FileEntry(path: "espeak-ng-data/lang/trk/kk", size: 40),
        FileEntry(path: "espeak-ng-data/lang/trk/ky", size: 43),
        FileEntry(path: "espeak-ng-data/lang/trk/nog", size: 39),
        FileEntry(path: "espeak-ng-data/lang/trk/tk", size: 25),
        FileEntry(path: "espeak-ng-data/lang/trk/tr", size: 25),
        FileEntry(path: "espeak-ng-data/lang/trk/tt", size: 23),
        FileEntry(path: "espeak-ng-data/lang/trk/ug", size: 24),
        FileEntry(path: "espeak-ng-data/lang/trk/uz", size: 39),
        FileEntry(path: "espeak-ng-data/lang/urj/et", size: 237),
        FileEntry(path: "espeak-ng-data/lang/urj/fi", size: 237),
        FileEntry(path: "espeak-ng-data/lang/urj/hu", size: 73),
        FileEntry(path: "espeak-ng-data/lang/urj/smj", size: 45),
        FileEntry(path: "espeak-ng-data/lang/zle/be", size: 52),
        FileEntry(path: "espeak-ng-data/lang/zle/ru", size: 57),
        FileEntry(path: "espeak-ng-data/lang/zle/ru-LV", size: 280),
        FileEntry(path: "espeak-ng-data/lang/zle/ru-cl", size: 91),
        FileEntry(path: "espeak-ng-data/lang/zle/uk", size: 97),
        FileEntry(path: "espeak-ng-data/lang/zls/bg", size: 111),
        FileEntry(path: "espeak-ng-data/lang/zls/bs", size: 230),
        FileEntry(path: "espeak-ng-data/lang/zls/hr", size: 262),
        FileEntry(path: "espeak-ng-data/lang/zls/mk", size: 28),
        FileEntry(path: "espeak-ng-data/lang/zls/sl", size: 43),
        FileEntry(path: "espeak-ng-data/lang/zls/sr", size: 250),
        FileEntry(path: "espeak-ng-data/lang/zlw/cs", size: 23),
        FileEntry(path: "espeak-ng-data/lang/zlw/pl", size: 38),
        FileEntry(path: "espeak-ng-data/lang/zlw/sk", size: 24),
        FileEntry(path: "espeak-ng-data/lb_dict", size: 687931),
        FileEntry(path: "espeak-ng-data/lfn_dict", size: 2793),
        FileEntry(path: "espeak-ng-data/lt_dict", size: 49890),
        FileEntry(path: "espeak-ng-data/lv_dict", size: 66337),
        FileEntry(path: "espeak-ng-data/mi_dict", size: 1346),
        FileEntry(path: "espeak-ng-data/mk_dict", size: 63859),
        FileEntry(path: "espeak-ng-data/ml_dict", size: 92345),
        FileEntry(path: "espeak-ng-data/mr_dict", size: 87391),
        FileEntry(path: "espeak-ng-data/ms_dict", size: 53541),
        FileEntry(path: "espeak-ng-data/mt_dict", size: 4384),
        FileEntry(path: "espeak-ng-data/mto_dict", size: 3960),
        FileEntry(path: "espeak-ng-data/my_dict", size: 95948),
        FileEntry(path: "espeak-ng-data/nci_dict", size: 1534),
        FileEntry(path: "espeak-ng-data/ne_dict", size: 95377),
        FileEntry(path: "espeak-ng-data/nl_dict", size: 65979),
        FileEntry(path: "espeak-ng-data/no_dict", size: 4178),
        FileEntry(path: "espeak-ng-data/nog_dict", size: 3294),
        FileEntry(path: "espeak-ng-data/om_dict", size: 2302),
        FileEntry(path: "espeak-ng-data/or_dict", size: 89246),
        FileEntry(path: "espeak-ng-data/pa_dict", size: 79953),
        FileEntry(path: "espeak-ng-data/pap_dict", size: 2128),
        FileEntry(path: "espeak-ng-data/phondata", size: 550424),
        FileEntry(path: "espeak-ng-data/phondata-manifest", size: 21821),
        FileEntry(path: "espeak-ng-data/phonindex", size: 39074),
        FileEntry(path: "espeak-ng-data/phontab", size: 55796),
        FileEntry(path: "espeak-ng-data/piqd_dict", size: 1710),
        FileEntry(path: "espeak-ng-data/pl_dict", size: 76730),
        FileEntry(path: "espeak-ng-data/pt_dict", size: 67817),
        FileEntry(path: "espeak-ng-data/py_dict", size: 2409),
        FileEntry(path: "espeak-ng-data/qdb_dict", size: 3028),
        FileEntry(path: "espeak-ng-data/qu_dict", size: 1919),
        FileEntry(path: "espeak-ng-data/quc_dict", size: 1450),
        FileEntry(path: "espeak-ng-data/qya_dict", size: 1939),
        FileEntry(path: "espeak-ng-data/ro_dict", size: 68538),
        FileEntry(path: "espeak-ng-data/ru_dict", size: 8532392),
        FileEntry(path: "espeak-ng-data/sd_dict", size: 59928),
        FileEntry(path: "espeak-ng-data/shn_dict", size: 88172),
        FileEntry(path: "espeak-ng-data/si_dict", size: 85384),
        FileEntry(path: "espeak-ng-data/sjn_dict", size: 1783),
        FileEntry(path: "espeak-ng-data/sk_dict", size: 50002),
        FileEntry(path: "espeak-ng-data/sl_dict", size: 45047),
        FileEntry(path: "espeak-ng-data/smj_dict", size: 35095),
        FileEntry(path: "espeak-ng-data/sq_dict", size: 45003),
        FileEntry(path: "espeak-ng-data/sr_dict", size: 46832),
        FileEntry(path: "espeak-ng-data/sv_dict", size: 47836),
        FileEntry(path: "espeak-ng-data/sw_dict", size: 47804),
        FileEntry(path: "espeak-ng-data/ta_dict", size: 209553),
        FileEntry(path: "espeak-ng-data/te_dict", size: 94837),
        FileEntry(path: "espeak-ng-data/th_dict", size: 2301),
        FileEntry(path: "espeak-ng-data/tk_dict", size: 20868),
        FileEntry(path: "espeak-ng-data/tn_dict", size: 3072),
        FileEntry(path: "espeak-ng-data/tr_dict", size: 46793),
        FileEntry(path: "espeak-ng-data/tt_dict", size: 2121),
        FileEntry(path: "espeak-ng-data/ug_dict", size: 2070),
        FileEntry(path: "espeak-ng-data/uk_dict", size: 3492),
        FileEntry(path: "espeak-ng-data/ur_dict", size: 133556),
        FileEntry(path: "espeak-ng-data/uz_dict", size: 2540),
        FileEntry(path: "espeak-ng-data/vi_dict", size: 52608),
        FileEntry(path: "espeak-ng-data/voices/!v/Alex", size: 128),
        FileEntry(path: "espeak-ng-data/voices/!v/Alicia", size: 474),
        FileEntry(path: "espeak-ng-data/voices/!v/Andrea", size: 357),
        FileEntry(path: "espeak-ng-data/voices/!v/Andy", size: 320),
        FileEntry(path: "espeak-ng-data/voices/!v/Annie", size: 315),
        FileEntry(path: "espeak-ng-data/voices/!v/AnxiousAndy", size: 361),
        FileEntry(path: "espeak-ng-data/voices/!v/Demonic", size: 3858),
        FileEntry(path: "espeak-ng-data/voices/!v/Denis", size: 305),
        FileEntry(path: "espeak-ng-data/voices/!v/Diogo", size: 379),
        FileEntry(path: "espeak-ng-data/voices/!v/Gene", size: 281),
        FileEntry(path: "espeak-ng-data/voices/!v/Gene2", size: 283),
        FileEntry(path: "espeak-ng-data/voices/!v/Henrique", size: 381),
        FileEntry(path: "espeak-ng-data/voices/!v/Hugo", size: 378),
        FileEntry(path: "espeak-ng-data/voices/!v/Jacky", size: 267),
        FileEntry(path: "espeak-ng-data/voices/!v/Lee", size: 338),
        FileEntry(path: "espeak-ng-data/voices/!v/Marco", size: 467),
        FileEntry(path: "espeak-ng-data/voices/!v/Mario", size: 270),
        FileEntry(path: "espeak-ng-data/voices/!v/Michael", size: 270),
        FileEntry(path: "espeak-ng-data/voices/!v/Mike", size: 112),
        FileEntry(path: "espeak-ng-data/voices/!v/Mr serious", size: 3193),
        FileEntry(path: "espeak-ng-data/voices/!v/Nguyen", size: 280),
        FileEntry(path: "espeak-ng-data/voices/!v/Reed", size: 202),
        FileEntry(path: "espeak-ng-data/voices/!v/RicishayMax", size: 233),
        FileEntry(path: "espeak-ng-data/voices/!v/RicishayMax2", size: 435),
        FileEntry(path: "espeak-ng-data/voices/!v/RicishayMax3", size: 435),
        FileEntry(path: "espeak-ng-data/voices/!v/Storm", size: 420),
        FileEntry(path: "espeak-ng-data/voices/!v/Tweaky", size: 3189),
        FileEntry(path: "espeak-ng-data/voices/!v/UniRobot", size: 417),
        FileEntry(path: "espeak-ng-data/voices/!v/adam", size: 75),
        FileEntry(path: "espeak-ng-data/voices/!v/anika", size: 493),
        FileEntry(path: "espeak-ng-data/voices/!v/anikaRobot", size: 512),
        FileEntry(path: "espeak-ng-data/voices/!v/announcer", size: 300),
        FileEntry(path: "espeak-ng-data/voices/!v/antonio", size: 381),
        FileEntry(path: "espeak-ng-data/voices/!v/aunty", size: 358),
        FileEntry(path: "espeak-ng-data/voices/!v/belinda", size: 340),
        FileEntry(path: "espeak-ng-data/voices/!v/benjamin", size: 201),
        FileEntry(path: "espeak-ng-data/voices/!v/boris", size: 224),
        FileEntry(path: "espeak-ng-data/voices/!v/caleb", size: 57),
        FileEntry(path: "espeak-ng-data/voices/!v/croak", size: 93),
        FileEntry(path: "espeak-ng-data/voices/!v/david", size: 112),
        FileEntry(path: "espeak-ng-data/voices/!v/ed", size: 287),
        FileEntry(path: "espeak-ng-data/voices/!v/edward", size: 151),
        FileEntry(path: "espeak-ng-data/voices/!v/edward2", size: 152),
        FileEntry(path: "espeak-ng-data/voices/!v/f1", size: 324),
        FileEntry(path: "espeak-ng-data/voices/!v/f2", size: 357),
        FileEntry(path: "espeak-ng-data/voices/!v/f3", size: 375),
        FileEntry(path: "espeak-ng-data/voices/!v/f4", size: 350),
        FileEntry(path: "espeak-ng-data/voices/!v/f5", size: 432),
        FileEntry(path: "espeak-ng-data/voices/!v/fast", size: 149),
        FileEntry(path: "espeak-ng-data/voices/!v/grandma", size: 263),
        FileEntry(path: "espeak-ng-data/voices/!v/grandpa", size: 256),
        FileEntry(path: "espeak-ng-data/voices/!v/gustave", size: 253),
        FileEntry(path: "espeak-ng-data/voices/!v/ian", size: 3168),
        FileEntry(path: "espeak-ng-data/voices/!v/iven", size: 261),
        FileEntry(path: "espeak-ng-data/voices/!v/iven2", size: 279),
        FileEntry(path: "espeak-ng-data/voices/!v/iven3", size: 262),
        FileEntry(path: "espeak-ng-data/voices/!v/iven4", size: 261),
        FileEntry(path: "espeak-ng-data/voices/!v/john", size: 3186),
        FileEntry(path: "espeak-ng-data/voices/!v/kaukovalta", size: 361),
        FileEntry(path: "espeak-ng-data/voices/!v/klatt", size: 38),
        FileEntry(path: "espeak-ng-data/voices/!v/klatt2", size: 38),
        FileEntry(path: "espeak-ng-data/voices/!v/klatt3", size: 39),
        FileEntry(path: "espeak-ng-data/voices/!v/klatt4", size: 39),
        FileEntry(path: "espeak-ng-data/voices/!v/klatt5", size: 39),
        FileEntry(path: "espeak-ng-data/voices/!v/klatt6", size: 39),
        FileEntry(path: "espeak-ng-data/voices/!v/linda", size: 350),
        FileEntry(path: "espeak-ng-data/voices/!v/m1", size: 335),
        FileEntry(path: "espeak-ng-data/voices/!v/m2", size: 264),
        FileEntry(path: "espeak-ng-data/voices/!v/m3", size: 300),
        FileEntry(path: "espeak-ng-data/voices/!v/m4", size: 290),
        FileEntry(path: "espeak-ng-data/voices/!v/m5", size: 262),
        FileEntry(path: "espeak-ng-data/voices/!v/m6", size: 188),
        FileEntry(path: "espeak-ng-data/voices/!v/m7", size: 254),
        FileEntry(path: "espeak-ng-data/voices/!v/m8", size: 284),
        FileEntry(path: "espeak-ng-data/voices/!v/marcelo", size: 251),
        FileEntry(path: "espeak-ng-data/voices/!v/max", size: 225),
        FileEntry(path: "espeak-ng-data/voices/!v/michel", size: 404),
        FileEntry(path: "espeak-ng-data/voices/!v/miguel", size: 382),
        FileEntry(path: "espeak-ng-data/voices/!v/mike2", size: 188),
        FileEntry(path: "espeak-ng-data/voices/!v/norbert", size: 3189),
        FileEntry(path: "espeak-ng-data/voices/!v/pablo", size: 3142),
        FileEntry(path: "espeak-ng-data/voices/!v/paul", size: 284),
        FileEntry(path: "espeak-ng-data/voices/!v/pedro", size: 352),
        FileEntry(path: "espeak-ng-data/voices/!v/quincy", size: 354),
        FileEntry(path: "espeak-ng-data/voices/!v/rob", size: 265),
        FileEntry(path: "espeak-ng-data/voices/!v/robert", size: 274),
        FileEntry(path: "espeak-ng-data/voices/!v/robosoft", size: 451),
        FileEntry(path: "espeak-ng-data/voices/!v/robosoft2", size: 454),
        FileEntry(path: "espeak-ng-data/voices/!v/robosoft3", size: 455),
        FileEntry(path: "espeak-ng-data/voices/!v/robosoft4", size: 447),
        FileEntry(path: "espeak-ng-data/voices/!v/robosoft5", size: 445),
        FileEntry(path: "espeak-ng-data/voices/!v/robosoft6", size: 287),
        FileEntry(path: "espeak-ng-data/voices/!v/robosoft7", size: 410),
        FileEntry(path: "espeak-ng-data/voices/!v/robosoft8", size: 243),
        FileEntry(path: "espeak-ng-data/voices/!v/sandro", size: 530),
        FileEntry(path: "espeak-ng-data/voices/!v/shelby", size: 280),
        FileEntry(path: "espeak-ng-data/voices/!v/steph", size: 364),
        FileEntry(path: "espeak-ng-data/voices/!v/steph2", size: 367),
        FileEntry(path: "espeak-ng-data/voices/!v/steph3", size: 377),
        FileEntry(path: "espeak-ng-data/voices/!v/travis", size: 383),
        FileEntry(path: "espeak-ng-data/voices/!v/victor", size: 253),
        FileEntry(path: "espeak-ng-data/voices/!v/whisper", size: 186),
        FileEntry(path: "espeak-ng-data/voices/!v/whisperf", size: 392),
        FileEntry(path: "espeak-ng-data/voices/!v/zac", size: 275),
        FileEntry(path: "espeak-ng-data/yue_dict", size: 563571),
        FileEntry(path: "lexicon-gb-en.txt", size: 6366635),
        FileEntry(path: "lexicon-us-en.txt", size: 5956885),
        FileEntry(path: "lexicon-zh.txt", size: 2364621),
        FileEntry(path: "model.int8.onnx", size: 114298054),
        FileEntry(path: "number-zh.fst", size: 64482),
        FileEntry(path: "phone-zh.fst", size: 88630),
        FileEntry(path: "tokens.txt", size: 687),
        FileEntry(path: "voices.bin", size: 27678720),
    ]

    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// 判定模型是否完整（逐文件校验大小）
    static func isComplete(in directory: URL) -> Bool {
        let fm = FileManager.default
        return files.allSatisfy { entry in
            let url = directory.appendingPathComponent(entry.path)
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
                return false
            }
            return size.int64Value == entry.size
        }
    }

    /// 已存在但校验不过（下载损坏）的文件路径，重新下载前先删掉
    static func corruptEntries(in directory: URL) -> [FileEntry] {
        let fm = FileManager.default
        return files.filter { entry in
            let url = directory.appendingPathComponent(entry.path)
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
                return false
            }
            return size.int64Value != entry.size
        }
    }

    static func existingBytes(in directory: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for entry in files {
            let url = directory.appendingPathComponent(entry.path)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
               size.int64Value == entry.size {
                total += entry.size
            }
        }
        return total
    }
}

// MARK: - Kokoro 推理引擎（经 LlamaCore/kokoro_bridge 的 C 桥接）

/// 线程安全的引擎句柄。创建与生成都可能耗时（模型加载数秒 / 合成按句子数），
/// 全部放在后台任务里调用；同一时刻只应有一个生成任务。
final class KokoroEngine: @unchecked Sendable {

    private var tts: UnsafeMutableRawPointer?
    private let lock = NSLock()

    enum EngineError: LocalizedError {
        case modelMissing
        case initFailed
        case generateFailed

        var errorDescription: String? {
            switch self {
            case .modelMissing: return "Kokoro 模型未就绪"
            case .initFailed: return "Kokoro 引擎初始化失败"
            case .generateFailed: return "语音合成失败"
            }
        }
    }

    init(modelDirectory: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard KokoroModelManifest.isComplete(in: modelDirectory) else {
            throw EngineError.modelMissing
        }

        func cstr(_ s: String) -> UnsafeMutablePointer<CChar> { strdup(s)! }

        let modelPath = cstr(modelDirectory.appendingPathComponent("model.int8.onnx").path)
        let voicesPath = cstr(modelDirectory.appendingPathComponent("voices.bin").path)
        let tokensPath = cstr(modelDirectory.appendingPathComponent("tokens.txt").path)
        let dataDirPath = cstr(modelDirectory.appendingPathComponent("espeak-ng-data").path)
        let lexiconPath = cstr(
            modelDirectory.appendingPathComponent("lexicon-us-en.txt").path + "," +
            modelDirectory.appendingPathComponent("lexicon-zh.txt").path
        )
        let ruleFstsPath = cstr(
            modelDirectory.appendingPathComponent("number-zh.fst").path + "," +
            modelDirectory.appendingPathComponent("phone-zh.fst").path + "," +
            modelDirectory.appendingPathComponent("date-zh.fst").path
        )
        // 路径字符串在 kokoro_tts_create 内部已被拷贝进 std::string，创建后统一释放
        defer {
            free(modelPath); free(voicesPath); free(tokensPath)
            free(dataDirPath); free(lexiconPath); free(ruleFstsPath)
        }

        guard let handle: UnsafeMutableRawPointer = kokoro_tts_create(
            modelPath, voicesPath, tokensPath, dataDirPath, lexiconPath, ruleFstsPath, 2
        ) else { throw EngineError.initFailed }
        tts = handle
    }

    deinit {
        if let tts { kokoro_tts_destroy(tts) }
    }

    var sampleRate: Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let tts else { return 24000 }
        return kokoro_tts_sample_rate(tts)
    }

    /// 合成语音，返回 (24kHz float 单声道样本, 采样率)
    func generate(text: String, voiceID: String, speed: Float) throws -> ([Float], Int32) {
        lock.lock(); defer { lock.unlock() }
        guard let tts else { throw EngineError.modelMissing }
        guard !text.isEmpty else { return ([], 24000) }

        var n: Int32 = 0
        var rate: Int32 = 24000
        let samples = kokoro_tts_generate(
            tts, text, KokoroVoices.sid(for: voiceID), speed, 0.2, &n, &rate
        )
        guard let samples else { throw EngineError.generateFailed }
        guard n > 0 else {
            kokoro_tts_free_audio(samples)
            throw EngineError.generateFailed
        }
        let count = Int(n)
        let buffer = UnsafeBufferPointer(start: samples, count: count)
        let result = Array(buffer)
        kokoro_tts_free_audio(samples)
        return (result, rate)
    }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if let tts { kokoro_tts_destroy(tts) }
        tts = nil
    }
}

// MARK: - 下载管理

@MainActor
final class KokoroTTSManager: ObservableObject {

    static let shared = KokoroTTSManager()

    enum State: Equatable {
        case idle
        case downloading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// 0...1（按字节数）
    @Published private(set) var progress: Double = 0
    /// 供 UI 提示当前正在下载哪个文件
    @Published private(set) var currentFile: String = ""

    private var downloadTask: Task<Void, Never>?

    /// 模型目录（纯路径计算，无 UI 依赖）
    nonisolated static var modelDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("KokoroTTS", isDirectory: true)
    }

    var isReady: Bool { KokoroModelManifest.isComplete(in: Self.modelDirectory) }

    init() {
        refreshState()
    }

    func refreshState() {
        if state != .downloading {
            state = isReady ? .ready : .idle
            progress = isReady ? 1 : 0
        }
    }

    // MARK: 下载

    func startDownload() {
        guard state != .downloading else { return }
        state = .downloading
        lastErrorReset()
        let dir = Self.modelDirectory
        downloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.downloadAll(to: dir) { phase, _ in
                Task { @MainActor in
                    guard let self else { return }
                    switch phase {
                    case .file(let name): self.currentFile = name
                    case .progress(let p): self.progress = p
                    case .done:
                        self.state = .ready
                        self.progress = 1
                        self.currentFile = ""
                    case .failed(let msg):
                        self.state = .failed(msg)
                        self.currentFile = ""
                    }
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = isReady ? .ready : .idle
        currentFile = ""
    }

    func deleteModel() {
        downloadTask?.cancel()
        downloadTask = nil
        try? FileManager.default.removeItem(at: Self.modelDirectory)
        state = .idle
        progress = 0
    }

    private func lastErrorReset() {
        if case .failed = state { state = .idle }
    }

    // MARK: 引擎

    /// 取可用引擎；模型就绪时创建并缓存（线程安全，模型加载约需数秒，勿在主线程直接调用）
    nonisolated static func engine() throws -> KokoroEngine {
        try KokoroEngineCache.get()
    }

    static func invalidateEngine() {
        KokoroEngineCache.invalidate()
    }

    // MARK: 下载实现

    private enum ProgressPhase {
        case file(String)
        case progress(Double)
        case done
        case failed(String)
    }

    /// 顺序下载大文件，随后并发下载 espeak 小文件
    nonisolated private static func downloadAll(
        to directory: URL,
        report: @escaping @Sendable (ProgressPhase, Double) -> Void
    ) async {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            // 先清掉历史损坏文件
            for entry in KokoroModelManifest.corruptEntries(in: directory) {
                try? fm.removeItem(at: directory.appendingPathComponent(entry.path))
            }

            let total = KokoroModelManifest.totalBytes
            var done: Int64 = KokoroModelManifest.existingBytes(in: directory)

            let bigFiles = KokoroModelManifest.files.filter { !$0.path.hasPrefix("espeak-ng-data/") }
            let espeakFiles = KokoroModelManifest.files.filter { $0.path.hasPrefix("espeak-ng-data/") }

            func updateProgress() {
                let p = total > 0 ? Double(done) / Double(total) : 0
                report(.progress(min(max(p, 0), 1)), 0)
            }

            // 大文件逐个下（保留进度粒度）
            for entry in bigFiles {
                try Task.checkCancellation()
                let dest = directory.appendingPathComponent(entry.path)
                if fileSizeOK(entry, at: dest) { continue }
                report(.file(entry.path), 0)
                let base = done
                try await downloadEntry(entry, to: directory, progress: { written in
                    let p = Double(base + written) / Double(total)
                    report(.progress(min(max(p, 0), 1)), 0)
                })
                done += entry.size
                updateProgress()
            }

            // espeak 小文件 4 路并发
            try await withThrowingTaskGroup(of: Int64.self) { group in
                var iterator = espeakFiles.makeIterator()
                var inflight = 0
                func addNext() throws {
                    guard Task.isCancelled == false else { return }
                    if let entry = iterator.next() {
                        inflight += 1
                        group.addTask {
                            let dest = directory.appendingPathComponent(entry.path)
                            if fileSizeOK(entry, at: dest) { return entry.size }
                            try await downloadEntry(entry, to: directory, progress: nil)
                            return entry.size
                        }
                    }
                }
                for _ in 0..<4 { try addNext() }
                while inflight > 0 {
                    do {
                        done += try await group.next()!
                        inflight -= 1
                    } catch is CancellationError {
                        group.cancelAll()
                        throw CancellationError()
                    }
                    updateProgress()
                    try addNext()
                }
            }

            // 校验完整性
            guard KokoroModelManifest.isComplete(in: directory) else {
                report(.failed("文件校验失败，请重试"), 0)
                return
            }
            KokoroEngineCache.invalidate()
            report(.done, 1)
        } catch is CancellationError {
            report(.failed("已取消"), 0)
        } catch {
            report(.failed("下载失败: \(error.localizedDescription)"), 0)
        }
    }

    private nonisolated static func fileSizeOK(_ entry: KokoroModelManifest.FileEntry, at url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return false
        }
        return size.int64Value == entry.size
    }

    /// 单文件下载：URLSessionDownloadTask（真进度回调），失败自动切换镜像源重试
    nonisolated private static func downloadEntry(
        _ entry: KokoroModelManifest.FileEntry,
        to directory: URL,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        let dest = directory.appendingPathComponent(entry.path)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var lastError: Error = URLError(.badURL)
        for base in KokoroModelManifest.baseURLs {
            do {
                let url = URL(string: "\(base)/\(KokoroModelManifest.repoID)/resolve/main/\(entry.path)")!
                try await downloadFile(from: url, to: dest, expected: entry.size, progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: dest)
            }
        }
        throw lastError
    }

    // MARK: - 下载器（delegate 进度回调）

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let onProgress: @Sendable (Int64, Int64) -> Void
        private var session: URLSession?
        private var continuation: CheckedContinuation<Void, Error>?
        private let stateLock = NSLock()
        private var resumed = false

        init(destination: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.destination = destination
            self.onProgress = onProgress
        }

        func attach(_ continuation: CheckedContinuation<Void, Error>, session: URLSession) {
            stateLock.lock(); defer { stateLock.unlock() }
            self.continuation = continuation
            self.session = session
        }

        /// 取消当前下载（触发 didCompleteWithError → continuation 以取消错误 resume）
        func cancelAll() {
            stateLock.lock(); let s = session; stateLock.unlock()
            s?.invalidateAndCancel()
        }

        private func finish(_ result: Result<Void, Error>) {
            stateLock.lock(); defer { stateLock.unlock() }
            guard !resumed else { return }
            resumed = true
            switch result {
            case .success: continuation?.resume(returning: ())
            case .failure(let error): continuation?.resume(throwing: error)
            }
            continuation = nil
            session = nil
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: location, to: destination)
                finish(.success(()))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            onProgress(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                let ns = error as NSError
                if ns.code == NSURLErrorCancelled {
                    finish(.failure(CancellationError()))
                } else {
                    finish(.failure(error))
                }
            }
        }
    }

    nonisolated private static func downloadFile(
        from url: URL,
        to dest: URL,
        expected: Int64,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws {
        let delegate = DownloadDelegate(destination: dest) { written, _ in
            progress?(written)
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60 * 6
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.attach(continuation, session: session)
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            delegate.cancelAll()
        }

        // 大小校验（不符视为坏下载，交由镜像重试逻辑）
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber
        guard size?.int64Value == expected else {
            try? FileManager.default.removeItem(at: dest)
            throw URLError(.zeroByteResource)
        }
    }
}

// MARK: - 线程安全的引擎缓存

enum KokoroEngineCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: KokoroEngine?

    static func get() throws -> KokoroEngine {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let dir = KokoroTTSManager.modelDirectory
        let engine = try KokoroEngine(modelDirectory: dir)
        cached = engine
        return engine
    }

    static func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cached?.shutdown()
        cached = nil
    }
}

// MARK: - WAV 封装（float PCM → 16bit WAV Data）

enum WAVWriter {
    static func wavData(samples: [Float], sampleRate: Int32) -> Data {
        let sampleCount = samples.count
        let dataSize = sampleCount * 2
        var data = Data(capacity: 44 + dataSize)

        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        func appendString(_ s: String) { data.append(contentsOf: s.utf8) }

        appendString("RIFF")
        append(Int32(36 + dataSize).littleEndian)
        appendString("WAVE")
        appendString("fmt ")
        append(Int32(16).littleEndian)          // fmt chunk size
        append(Int16(1).littleEndian)           // PCM
        append(Int16(1).littleEndian)           // mono
        append(Int32(sampleRate).littleEndian)
        append(Int32(sampleRate * 2).littleEndian) // byte rate
        append(Int16(2).littleEndian)           // block align
        append(Int16(16).littleEndian)          // bits
        appendString("data")
        append(Int32(dataSize).littleEndian)

        samples.withUnsafeBufferPointer { buf in
            for i in 0..<sampleCount {
                let v = max(-1, min(1, buf[i]))
                append(Int16(v * 32767).littleEndian)
            }
        }
        return data
    }
}
