import Foundation

/// The families Dewline installs on request (synthesis 2.9). Every file is pinned to one commit of google/fonts by
/// URL, byte size and SHA-256, so a download either matches what was reviewed here or is refused. All are under the
/// SIL Open Font License 1.1, and each family's OFL.txt installs with it.
enum FontCatalog {
    static let commit = "e7db6ca603fd4862010383ff17ffd6cc4ffac1c0"

    struct Family: Identifiable, Sendable {
        enum Role: String, Sendable {
            case serif = "Serif", sans = "Sans", mono = "Mono", display = "Display"
        }

        let name: String
        let role: Role
        /// The family's folder in google/fonts, under ofl/.
        let folder: String
        let why: String
        let project: String
        let license = "SIL Open Font License 1.1"
        let files: [File]

        var id: String { name }
        var size: Int { files.reduce(0) { $0 + $1.size } }

        func url(_ file: File) -> URL {
            URL(string: "https://raw.githubusercontent.com/google/fonts/\(FontCatalog.commit)/ofl/\(folder)")!.appending(path: file.name)
        }
    }

    struct File: Sendable {
        let name: String
        let size: Int
        let sha256: String
    }

    static func family(_ name: String) -> Family? {
        families.first { $0.name == name }
    }

    static let families: [Family] = [
        Family(
            name: "Newsreader", role: .serif, folder: "newsreader",
            why: "Headings, Editorial titles and the wordmark; optical sizes 6 to 72",
            project: "https://github.com/productiontype/Newsreader",
            files: [
                File(name: "Newsreader-Italic[opsz,wght].ttf", size: 495684, sha256: "796668611f80b64d5adf182fde3b6f29ed83b4e7cbec7b96937e84ac01364792"),
                File(name: "Newsreader[opsz,wght].ttf", size: 451664, sha256: "8a08d13f8a6c0d51be379a60af84f945f65369a67e509ee3c3bdcc421254d7c1"),
                File(name: "OFL.txt", size: 4394, sha256: "fdfad38143ec470553cae82a1e45320bdd1b9ec70415d37bd0171051d8a4ded8"),
            ]
        ),
        Family(
            name: "Literata", role: .serif, folder: "literata",
            why: "Drawn for hours of screen reading; the long-form alternative to New York",
            project: "https://github.com/googlefonts/literata",
            files: [
                File(name: "Literata-Italic[opsz,wght].ttf", size: 902728, sha256: "d483dfaeba9cbf4ce71d32a52ee65df82f7e35b15fff8d1011cdb242d1fcd465"),
                File(name: "Literata[opsz,wght].ttf", size: 955132, sha256: "b41138c9373112f32abb589cc22e8674b06ed4048b0c513be922bdd26f274440"),
                File(name: "OFL.txt", size: 4389, sha256: "8742963604cd89dc81437811a850018fc03b2bfad686d7422c8235967c87614e"),
            ]
        ),
        Family(
            name: "Source Serif 4", role: .serif, folder: "sourceserif4",
            why: "An optical-size serif, crisp at 15 pt on non-Retina screens",
            project: "https://github.com/adobe-fonts/source-serif",
            files: [
                File(name: "SourceSerif4-Italic[opsz,wght].ttf", size: 855432, sha256: "15fbc7e4679489a501998c3669272637a6646388ef7e4bd77eebb5bf967a1f42"),
                File(name: "SourceSerif4[opsz,wght].ttf", size: 1209508, sha256: "97b2d4da6e3cb494b5a1e66ae176914d852ccabef49e0c02c0df25f3e39aca0b"),
                File(name: "OFL.txt", size: 4400, sha256: "5f94c3fd3a23131a417ab5a0c8452de57e70c3cfb9f604d88241f7065ebf9fd9"),
            ]
        ),
        Family(
            name: "EB Garamond", role: .serif, folder: "ebgaramond",
            why: "Literary drafts; true small caps and old-style figures",
            project: "https://github.com/octaviopardo/EBGaramond12",
            files: [
                File(name: "EBGaramond-Italic[wght].ttf", size: 754468, sha256: "bba2c4499c93c9612b90b9825d32b07da52fce2fe57562a1eb6b833553f93c4e"),
                File(name: "EBGaramond[wght].ttf", size: 851176, sha256: "ef9512f92f6d579e5dc75af59a5a4b1b8b47d2eda89e00b954d44520e5369027"),
                File(name: "OFL.txt", size: 4398, sha256: "0985066662eb755ed3683ae5482a81a9195b49ce3f7e165cc2388b3dbece7dd7"),
            ]
        ),
        Family(
            name: "Charis SIL", role: .serif, folder: "charissil",
            why: "Wide Latin, Cyrillic and IPA coverage, for names like Utqiaġvik",
            project: "https://github.com/silnrsi/font-charis",
            files: [
                File(name: "CharisSIL-Bold.ttf", size: 738488, sha256: "68460d2b76c8f781b49f9168f2c7dc3c9f7b788a3a1b8f267c5fa6bb47d5c64d"),
                File(name: "CharisSIL-BoldItalic.ttf", size: 802588, sha256: "acdf6dc54c0ee5e03cae3398f64133c335084cd1ecab655f2a8636c5d56acedb"),
                File(name: "CharisSIL-Italic.ttf", size: 775668, sha256: "e776e2961117b39cf924c0139de01748a77b2fcb99c437b2c77bdd9401606c13"),
                File(name: "CharisSIL-Regular.ttf", size: 752900, sha256: "346337374aa347d64ee015b26d441f1970d8631914e2f3941b00e1c4761e28c5"),
                File(name: "OFL.txt", size: 4505, sha256: "0acda775b4dedaf980821f590206a692779ee495170018ee2b9caf1c50fc136a"),
            ]
        ),
        Family(
            name: "Atkinson Hyperlegible Next", role: .sans, folder: "atkinsonhyperlegiblenext",
            why: "Designed for low vision; the Hyperlegible pairing",
            project: "https://github.com/googlefonts/atkinson-hyperlegible-next",
            files: [
                File(name: "AtkinsonHyperlegibleNext-Italic[wght].ttf", size: 123916, sha256: "ce9cffed32742ad2d9238c561a93220385e5934cdc02b8eb4097a50efa957dc6"),
                File(name: "AtkinsonHyperlegibleNext[wght].ttf", size: 114552, sha256: "5a455d1cfa099b601ab70751bb9673e8fe1854dc4500c80e1a220d0d75e31745"),
                File(name: "OFL.txt", size: 4431, sha256: "aca6a428580965d2297d1b718042dd427c2a9443ece3b0d02d758e161e0c4030"),
            ]
        ),
        Family(
            name: "IBM Plex Sans", role: .sans, folder: "ibmplexsans",
            why: "An engineered sans for specs and technical notes",
            project: "https://github.com/IBM/plex",
            files: [
                File(name: "IBMPlexSans-Italic[wdth,wght].ttf", size: 599624, sha256: "0b94c5e981993764db32bf9c610ecc60cbd34ad77ec2f10ba03c64ab75124d8e"),
                File(name: "IBMPlexSans[wdth,wght].ttf", size: 537244, sha256: "3b031aa4216174205bd8471f88a49b91f093169e9e87bd5262242bc5967fe2e3"),
                File(name: "OFL.txt", size: 4456, sha256: "7e6b2818edbd8f6a01ae80641cc8f16a51080d08fb4e532be3a0b6f74adb07da"),
            ]
        ),
        Family(
            name: "Inter", role: .sans, folder: "inter",
            why: "The screen sans people ask for by name",
            project: "https://github.com/rsms/inter",
            files: [
                File(name: "Inter-Italic[opsz,wght].ttf", size: 906596, sha256: "acd98e64795781b2058f07b18475e0ecee2a0fe2b42a49e2f9e37d0d6bf66ce6"),
                File(name: "Inter[opsz,wght].ttf", size: 876576, sha256: "29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031"),
                File(name: "OFL.txt", size: 4377, sha256: "5b9321a4298cfeb6b34354164a1c3afc3db114569984c502b9b35d988fd58c57"),
            ]
        ),
        Family(
            name: "IBM Plex Mono", role: .mono, folder: "ibmplexmono",
            why: "Drafting in mono; the open original behind iA Writer's fonts",
            project: "https://github.com/IBM/plex",
            files: [
                File(name: "IBMPlexMono-Bold.ttf", size: 137784, sha256: "ac27abd6450a64dd94467580a02fe6235156d5b92f2926ebbc8e7489df64e0be"),
                File(name: "IBMPlexMono-BoldItalic.ttf", size: 144512, sha256: "af4e05a761e98c1adf064c48a6352c9bec1a6ad70982cd2a544149323391f98e"),
                File(name: "IBMPlexMono-Italic.ttf", size: 143920, sha256: "3362fc791b0652193328b862c1c5f23a789bc7288b1617fa63302f88689a2a34"),
                File(name: "IBMPlexMono-Regular.ttf", size: 135580, sha256: "6a3412f058c7d8dfd9170c41e85ade48e5156ecb89356110ca57a0a27734af46"),
                File(name: "OFL.txt", size: 4456, sha256: "7e6b2818edbd8f6a01ae80641cc8f16a51080d08fb4e532be3a0b6f74adb07da"),
            ]
        ),
        Family(
            name: "Atkinson Hyperlegible Mono", role: .mono, folder: "atkinsonhyperlegiblemono",
            why: "Unambiguous 0 and O, 1, l and I; the Hyperlegible pairing",
            project: "https://github.com/googlefonts/atkinson-hyperlegible-next-mono",
            files: [
                File(name: "AtkinsonHyperlegibleMono-Italic[wght].ttf", size: 56364, sha256: "e18f523877530e4abe229df6a36d394326254da488a7f5abb9b7b5ea8f780cd4"),
                File(name: "AtkinsonHyperlegibleMono[wght].ttf", size: 53960, sha256: "5ce8b1698d1ded7dff2178c1a3ad159470085a58ea239e8b2cb88f4fb4a6f646"),
                File(name: "OFL.txt", size: 4436, sha256: "1ebb31cf7393164f20d10c1d48406cddb5314feff8465531cf1e4ba37e9dd740"),
            ]
        ),
        Family(
            name: "Courier Prime", role: .mono, folder: "courierprime",
            why: "Manuscript and screenplay drafts; the Manuscript pairing",
            project: "https://github.com/quoteunquoteapps/CourierPrime",
            files: [
                File(name: "CourierPrime-Bold.ttf", size: 72856, sha256: "ff1f38786c849d1c41fa8e447960abdb2bd75fdfb0cfcdeb524fad65a5af3638"),
                File(name: "CourierPrime-BoldItalic.ttf", size: 80872, sha256: "3355273f3ea6d6362658f9564f4e83d59e156cf1a182e3c1592b5c5943627dcc"),
                File(name: "CourierPrime-Italic.ttf", size: 79980, sha256: "f1b9a5829789f7e56432a9f3bc7665ef4531dbba1c112639e48bef39621a006b"),
                File(name: "CourierPrime-Regular.ttf", size: 71188, sha256: "72f793376f8e2841656bf21d77a5de010f2929bd6956a22ee848ad0c7eb978af"),
                File(name: "OFL.txt", size: 4403, sha256: "9a755af092b494944c99f471be6fddd19b006a448fefdc4717e4ee0aa09a97b0"),
            ]
        ),
        Family(
            name: "Fira Code", role: .mono, folder: "firacode",
            why: "Ligatures for code-heavy notes",
            project: "https://github.com/tonsky/FiraCode",
            files: [
                File(name: "FiraCode[wght].ttf", size: 260364, sha256: "9335b082b3c7850d98a64b584f3417f65355f3471278bb5eeb8c6c0e8657aeeb"),
                File(name: "OFL.txt", size: 4391, sha256: "926041dac670e6922505e35ac1661a4e8d20f1ffeabbbcb5edb5544370702369"),
            ]
        ),
        Family(
            name: "Source Code Pro", role: .mono, folder: "sourcecodepro",
            why: "Adobe's quiet coding mono; pairs with Source Serif 4",
            project: "https://github.com/adobe-fonts/source-code-pro",
            files: [
                File(name: "SourceCodePro-Italic[wght].ttf", size: 174852, sha256: "6db77d25aa7b30eff449305b5c998e475694c74d398421127ea5a60f536413cd"),
                File(name: "SourceCodePro[wght].ttf", size: 212340, sha256: "b400fc584e10aff25d0e775ce181b4fc1c5ea1b5dc37b81aeb2084375b945790"),
                File(name: "OFL.txt", size: 4622, sha256: "cb30d3086a8b3ce0b9e3690bf48d6620402b61160bc658076f95180ccd9e9dae"),
            ]
        ),
        Family(
            name: "Cascadia Code", role: .mono, folder: "cascadiacode",
            why: "Windows Terminal's face, with programming ligatures and a cursive italic",
            project: "https://github.com/microsoft/cascadia-code",
            files: [
                File(name: "CascadiaCode-Italic[wght].ttf", size: 530444, sha256: "33559b4beb60523b824e25a416b5de2779a9bc7c7ce32ce128490b42acbf4681"),
                File(name: "CascadiaCode[wght].ttf", size: 727940, sha256: "30f2e14a5c389b346b1fce110c4ddcf0dc5ce8265faf5eca2ab7323f49dba590"),
                File(name: "OFL.txt", size: 4395, sha256: "82c05d6c53dfa0c9025985c19e371810020b74ed2c61d51d370f2a8ab2506d52"),
            ]
        ),
        Family(
            name: "Victor Mono", role: .mono, folder: "victormono",
            why: "Narrow and tall, with a semi-connected cursive italic for comments",
            project: "https://github.com/rubjo/victor-mono",
            files: [
                File(name: "VictorMono-Italic[wght].ttf", size: 242872, sha256: "e393afee873d56e052c10bdfcbf67053c429895bd73a4f8e59100a09ffb9d8ec"),
                File(name: "VictorMono[wght].ttf", size: 194312, sha256: "6fab3abe37b456f56d180987e04a3a0c326bace2cb825bc638b6be1eb03edf8f"),
                File(name: "OFL.txt", size: 4395, sha256: "493589852331b4ea83f1d6b0cbdc157b002ffdb995cf2429acf0c9863bc8f3df"),
            ]
        ),
        Family(
            name: "Geist Mono", role: .mono, folder: "geistmono",
            why: "Vercel's crisp, geometric mono for terminals and editors",
            project: "https://github.com/vercel/geist-font",
            files: [
                File(name: "GeistMono-Italic[wght].ttf", size: 182656, sha256: "70c15be47d55f637197f7e38570dbca16b35777ea647dc3598f61bf3961d2b0d"),
                File(name: "GeistMono[wght].ttf", size: 171948, sha256: "d00e590b8eb3a59acc329b2d044fd143ae935090b7da33199ebee27cc7de8196"),
                File(name: "OFL.txt", size: 4387, sha256: "1781d2806a07d91c4edf4740b88449fab7d0eadad53f7c351b94cd4d4eb8c00f"),
            ]
        ),
        Family(
            name: "Inconsolata", role: .mono, folder: "inconsolata",
            why: "A humanist coding mono with a width axis for dense listings",
            project: "https://github.com/googlefonts/Inconsolata",
            files: [
                File(name: "Inconsolata[wdth,wght].ttf", size: 347180, sha256: "23ded25b447074d00659392bf9b1123d89df55cb07b0ad9bfef3366d199b5fcb"),
                File(name: "OFL.txt", size: 4350, sha256: "29bd0cfd0fb2a45f9b057c834a057724bae1f63b525a8ac83d3e7525706d9f80"),
            ]
        ),
        Family(
            name: "Fraunces", role: .display, folder: "fraunces",
            why: "Soft and Wonk axes for warm display headings",
            project: "https://github.com/undercasetype/Fraunces",
            files: [
                File(name: "Fraunces-Italic[SOFT,WONK,opsz,wght].ttf", size: 414904, sha256: "b24448c43702fac4ee856781d461a0dfba8d8e594b6e8e190234b75fed2c0e01"),
                File(name: "Fraunces[SOFT,WONK,opsz,wght].ttf", size: 360440, sha256: "177ff6c0f14e5550a3c624247cd1189611d4eb65d000b14944c63d967958abbb"),
                File(name: "OFL.txt", size: 4391, sha256: "bdf4c22802eaf804f998195871c6b8938aac2ac14b2d78a8bd66a6f1eced833b"),
            ]
        ),
        Family(
            name: "Recursive", role: .display, folder: "recursive",
            why: "One variable file from sans to mono to casual",
            project: "https://github.com/arrowtype/recursive",
            files: [
                File(name: "Recursive[CASL,CRSV,MONO,slnt,wght].ttf", size: 2379132, sha256: "653221ca467f4732fe6856ac493f6c409e9f56a7674abe36b2364acc89796f7c"),
                File(name: "OFL.txt", size: 4389, sha256: "f9f539cf7549bd417159dbdb9c400943a5b60a7366c2c6fbde9f095173d82479"),
            ]
        ),
        Family(
            name: "Instrument Serif", role: .display, folder: "instrumentserif",
            why: "A condensed display serif for big Editorial titles",
            project: "https://github.com/Instrument/instrument-serif",
            files: [
                File(name: "InstrumentSerif-Italic.ttf", size: 71592, sha256: "08939b8bdf534afec24ae0ef5e03f948940cd9a8fe08e7fecbad040e62327385"),
                File(name: "InstrumentSerif-Regular.ttf", size: 70012, sha256: "498efd461f6ddfcb7a111bf9a565709d2085d48201d501ead960d93e84ffbb88"),
                File(name: "OFL.txt", size: 4405, sha256: "129ed7618959716959f2941fdd5b49e0ad6e6c1d78726761786a00253d865521"),
            ]
        ),
    ]
}
