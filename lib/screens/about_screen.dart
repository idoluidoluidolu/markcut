import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/store_links.dart';
import '../theme.dart';
import 'playback_test_screen.dart';

/// 原始碼位置（MPL 要求提供取得方式）
const kSourceUrl = 'https://github.com/idoluidoluidolu/markcut';
const kAppVersion = '1.0.0';

/// 作者原文，分行照他寫的，不要自作主張重排
const kDeveloperIntro =
    '「浮水印」是一款完全免費的APP\n'
    '如果這款APP有幫助到你的話\n'
    '不用抖內我\n'
    '但請你幫我做一件事\n'
    '幫點一下下面的連結\n'
    '來下載我另外一個作品\n'
    '「留己看」 APP...\n'
    '留己看是一款可以儲存各大平台連結的APP\n'
    '圖片、影片、地圖、貼文都可以\n'
    '超方便\n'
    '真的很好用\n'
    '你用了就知道\n'
    '如果可以的話\n'
    '再幫我的留己看留一個好評...\n'
    '如果還可以的話\n'
    '請成為我的留己看會員\n'
    '如果真的超可以的話\n'
    '幫我到社群平台分享我的留己看APP...\n'
    '那我會非常感謝的！！！';

/// 關於：主畫面只放作者，授權／隱私這些收到頁尾的小連結裡
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('關於 浮水印'),
      ),
      body: SafeArea(
        // 頁尾跟著內容捲到最後，不釘在畫面底部
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          children: [
            // 吉祥物（跟首頁同一張），不寫名字和版本
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 20),
                child: SizedBox(
                  width: 220,
                  height: 88,
                  child: Image.asset(
                    'assets/icon/icon_foreground.png',
                    fit: BoxFit.cover, // 裁掉原圖四周的留白
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
            ),
            // 作者的話：置中對齊，不套卡片框。
            // 一堆長短不一的短句齊左會很雜，置中之後行尾對齊就整齊了
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                kDeveloperIntro,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: kTextDim,
                  height: 1.75,
                ),
              ),
            ),
            const SizedBox(height: 22),
            // 介紹文裡講的「下面的連結」就是這顆
            Builder(
              builder: (context) => FilledButton.icon(
                onPressed: () async {
                  final ok = await openLiuJiKan();
                  if (!ok && context.mounted) {
                    showHint(context, '開不了商店連結', error: true);
                  }
                },
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                ),
                icon: const Icon(Icons.open_in_new, size: 17),
                label: Text(
                  liuJiKanStoreLabel,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            // 除錯工具：卡頓時要你截圖回報用的，平常不會動到
            _card('除錯', [
              ValueListenableBuilder<bool>(
                valueListenable: kPerfOverlay,
                builder: (context, v, _) => Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '效能檢測模式',
                        style: TextStyle(fontSize: 12.5, color: kTextDim),
                      ),
                    ),
                    Switch(
                      value: v,
                      onChanged: (nv) => kPerfOverlay.value = nv,
                    ),
                  ],
                ),
              ),
              InkWell(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PlaybackTestScreen()),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '影片純播放測試',
                    style: TextStyle(fontSize: 12.5, color: kTextDim),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 20),
            _footer(context),
          ],
        ),
      ),
    );
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
            style: TextStyle(fontSize: 11, color: kTextDim),
          ),
        ],
      ),
    );
  }

  Widget _dot() => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 8),
    child: Text('·', style: TextStyle(fontSize: 12, color: kTextDim)),
  );

  Widget _link(BuildContext context, String label, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12.5, color: kText),
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
              '全部在你的裝置上',
              '所有影片與照片都在你的裝置上處理，'
                  '浮水印 不會上傳、不會蒐集個人資料，也沒有帳號系統。',
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
    decoration: BoxDecoration(
      // 純黑＋細邊線，跟個人中心同一套（不要滿頁深淺不一的灰）
      color: Colors.black,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: kClipBorder),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: kText,
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
    style: const TextStyle(fontSize: 12.5, color: kTextDim, height: 1.6),
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
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: kClipBorder),
        ),
        child: Row(
          children: [
            Icon(icon, size: 15, color: kAmber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: kText),
              ),
            ),
            const Icon(Icons.copy, size: 14, color: kTextDim),
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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: Text(title)),
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
                side: const BorderSide(color: kClipBorder),
                foregroundColor: kText,
              ),
              child: const Text('第三方套件授權清單', style: TextStyle(fontSize: 13)),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
