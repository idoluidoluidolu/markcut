import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../widgets/swipe_back.dart';

/// 原始碼位置（MPL 要求提供取得方式）
const kSourceUrl = 'https://github.com/idoluidoluidolu/markcut';
const kAppVersion = '1.0.0';

/// 作者原文，分行照他寫的，不要自作主張重排
const kDeveloperIntro =
    '「浮水印」是一款完全免費的APP\n'
    '「浮水印」是一款完全不用錢的APP\n'
    '「浮水印」是一款FREE的APP\n'
    '「浮水印」是一款不收費的APP\n'
    '「浮水印」是一款售價0元的APP';

/// 關於：主畫面只放作者，授權／隱私這些收到頁尾的小連結裡
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return LightPage(child: SwipeBack(
      child: Scaffold(
        backgroundColor: kLBg,
        appBar: AppBar(
          backgroundColor: kLBg,
          title: const Text('關於 浮水印'),
        ),
        body: SafeArea(
          // 內容垂直置中、頁尾釘在畫面底部
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, cons) => SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: cons.maxHeight),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 不放吉祥物：標題列已經寫著「關於 浮水印」，
                          // 進到這一頁的人不需要再被告知一次自己在哪
                          //
                          // 作者的話：置中對齊，不套卡片框
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              kDeveloperIntro,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: kLTextDim,
                                height: 1.75,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _footer(context),
            ],
          ),
        ),
      ),
    ));
  }

  /// 頁尾：授權相關全部收在這三個小連結裡
  Widget _footer(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _link(context, '開源授權', () => _openLicense(context)),
              _dot(),
              _link(context, '原始碼', () async {
                await Clipboard.setData(const ClipboardData(text: kSourceUrl));
                if (context.mounted) showHint(context, '已複製原始碼網址');
              }),
              _dot(),
              _link(context, '隱私', () => _openPrivacy(context)),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '依 MPL 2.0 散布 · FFmpeg LGPL v2.1+',
            style: TextStyle(fontSize: 11, color: kLTextDim),
          ),
        ],
      ),
    );
  }

  Widget _dot() => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 8),
    child: Text('·', style: TextStyle(fontSize: 12, color: kLTextDim)),
  );

  Widget _link(BuildContext context, String label, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(kTagRadius),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12.5, color: kLText),
        ),
      ),
    );
  }

  void _openLicense(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _InfoPage(
          title: '開源授權',
          sections: const [
            (
              '本程式',
              '浮水印 是自由軟體，依 Mozilla Public License 2.0 散布。\n\n'
                  '你可以自由使用、修改與再散布本程式；'
                  '改動到的原始檔必須以相同授權公開，'
                  '但可以跟其他授權的程式碼整合在同一個專案裡。'
                  '本程式不提供任何擔保。',
            ),
            (
              '影音處理',
              '影音處理由 FFmpeg（LGPL v2.1+）與 media_kit 提供，'
                  'H.264 編碼使用裝置的硬體編碼器。\n'
                  'FFmpeg 為其各自作者所有，詳見 ffmpeg.org。',
            ),
            (
              '內建字型（SIL Open Font License 1.1）',
              '思源黑體、思源宋體 — Google / Adobe\n'
                  'jf open 粉圓 — justfont\n'
                  'LXGW 文楷 TC — 落霞孤鶩\n'
                  '朱古力黑體 — Chocolate Classical Sans\n'
                  'Montserrat、Playfair Display、Pacifico、'
                  'Bebas Neue、Oswald、Lobster、Anton、Courier Prime',
            ),
          ],
          showSourceRow: true,
          showPackageList: true,
        ),
      ),
    );
  }

  void _openPrivacy(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const _InfoPage(
          title: '隱私',
          sections: [
            (
              '媒體全部在你的裝置上',
              '所有影片與照片都在你的裝置上處理，'
                  '不會上傳到任何伺服器，也沒有帳號系統。',
            ),
            (
              '意見回饋',
              '只有你主動送出「意見回饋」時，你填寫的訊息內容與'
                  '聯絡方式（選填）會傳送到開發者的伺服器，'
                  '僅用於回覆與改善 App，不會用於其他用途。',
            ),
          ],
        ),
      ),
    );
  }
}

// ===== 共用小元件 =====

Widget _card(String title, List<Widget> children) {
  return Container(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
    // 純白底＋柔和陰影，跟個人中心同一套
    decoration: lightCard(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: kLText,
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );
}

Widget _body(String text) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Text(
    text,
    style: const TextStyle(fontSize: 12.5, color: kLTextDim, height: 1.6),
  ),
);

/// 一行可複製的資訊（聯絡方式、原始碼網址）
Widget _copyRow({
  required IconData icon,
  required String text,
  required String copied,
}) {
  return Builder(
    builder: (context) => InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) showHint(context, copied);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: lightCard(radius: 6),
        child: Row(
          children: [
            Icon(icon, size: 15, color: kLAccent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: kLText),
              ),
            ),
            const Icon(Icons.copy, size: 14, color: kLTextDim),
          ],
        ),
      ),
    ),
  );
}

/// 頁尾連結點開的內容頁
class _InfoPage extends StatelessWidget {
  final String title;
  final List<(String, String)> sections;
  final bool showSourceRow;
  final bool showPackageList;

  const _InfoPage({
    required this.title,
    required this.sections,
    this.showSourceRow = false,
    this.showPackageList = false,
  });

  @override
  Widget build(BuildContext context) {
    return LightPage(child: SwipeBack(
      child: Scaffold(
        backgroundColor: kLBg,
        appBar: AppBar(backgroundColor: kLBg, title: Text(title)),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final (heading, text) in sections) ...[
              _card(heading, [_body(text)]),
              const SizedBox(height: 10),
            ],
            if (showSourceRow) ...[
              _copyRow(icon: Icons.code, text: kSourceUrl, copied: '已複製原始碼網址'),
              const SizedBox(height: 12),
            ],
            if (showPackageList)
              OutlinedButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: '浮水印',
                  applicationVersion: kAppVersion,
                  applicationLegalese: '依 MPL 2.0 散布',
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  side: const BorderSide(color: kLBorder),
                  foregroundColor: kLText,
                ),
                child: const Text('第三方套件授權清單', style: TextStyle(fontSize: 13)),
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    ));
  }
}
