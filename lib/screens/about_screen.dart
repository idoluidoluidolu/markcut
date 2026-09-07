import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/playback_trace.dart' show appVersionTag;
import '../theme.dart';
import '../widgets/swipe_back.dart';
import 'donate_screen.dart';
import 'probe_screen.dart';

/// 原始碼位置（MPL 要求提供取得方式）
const kSourceUrl = 'https://github.com/idoluidoluidolu/markcut';

// 版本號不寫死：以前這裡有個 kAppVersion = '1.0.0'，意見回饋與授權清單
// 都送它，實際早就是 1.1.0+18——後台收到的每一則回饋都對不到是哪個
// build 的問題。一律用 main.dart 從 PackageInfo 填進來的 appVersionTag

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
    return SwipeBack(
      child: Scaffold(
        backgroundColor: kLBg,
        appBar: AppBar(backgroundColor: kLBg),
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
    );
  }

  /// 頁尾：斗內那顆鈕壓在授權連結上面，授權相關全部收在小連結裡
  Widget _footer(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
      child: Column(
        children: [
          // 「太好用啦」：以前在個人中心是一顆滿版黑鈕，使用者把它從那裡
          // 拿掉、改放到這一頁的頁尾（六種擺法裡挑了「貼在頁尾連結上面」），
          // 字照舊叫「太好用啦」，按下去一樣進斗內頁
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _loveButton(context),
          ),
          // Wrap 不是 Row：四個連結加三個點在 1.2 字級約 290pt，320 寬
          // 的機子剛好塞得下，再多一個字就從兩側溢出。放不下就折到
          // 第二排
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _link(context, '開源授權', () => _openLicense(context)),
              _dot(),
              _link(context, '原始碼', () async {
                await Clipboard.setData(const ClipboardData(text: kSourceUrl));
                if (context.mounted) showHint(context, '已複製原始碼網址');
              }),
              _dot(),
              _link(context, '隱私', () => _openPrivacy(context)),
              _dot(),
              // 遠端使用者回報「影片沒畫面」時的一次定位工具。
              // 它是深色的除錯頁，不包 LightPage
              _link(
                context,
                '播放偵測',
                () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ProbeScreen()),
                ),
              ),
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

  /// 斗內鈕：黑色膠囊、愛心＋「太好用啦」，寬度隨字
  Widget _loveButton(BuildContext context) => Material(
    color: kLAccent,
    shape: const StadiumBorder(),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const LightPage(child: DonateScreen()),
        ),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 26),
        child: SizedBox(
          height: 50,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.favorite_border, size: 18, color: kLBg),
              SizedBox(width: 8),
              Text(
                '太好用啦',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  color: kLBg,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

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

  // 內容頁一定要包 LightPage：路由是掛在 Navigator 底下建的，拿到的是
  // App 層的深色佈景——頁面自己寫死的白底看起來是白的，但返回鍵會是
  // 深色頁的灰、從那頁開出來的套件授權清單整頁黑（見 light_page_route_test）
  void _openLicense(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const LightPage(
          child: _InfoPage(
            sections: [
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
                // 授權說法照 main 上 fix/health 訂的版本（FFmpeg 換成
                // 不含 GPL 元件的 LGPL 建置）：這一段是法律文字，
                // 只有那條分支能改，這裡只是原樣搬過來不要改回舊的
                '影音處理由 FFmpeg（LGPL v2.1+ 建置，不含 x264／x265 等 GPL '
                    '元件）提供，Android 的預覽播放另用 media_kit，'
                    'H.264 編碼使用裝置的硬體編碼器。\n'
                    'FFmpeg 為其各自作者所有，詳見 ffmpeg.org。',
              ),
              (
                '內建字型（SIL Open Font License 1.1）',
                '思源黑體、思源宋體 — Google / Adobe\n'
                    'jf open 粉圓 — justfont\n'
                    'LXGW 文楷 TC — 落霞孤鶩\n'
                    '悠哉字體 — 落霞孤鶩\n'
                    '縫合像素字體 — TakWolf\n'
                    'Montserrat、Playfair Display、Pacifico、'
                    'Bebas Neue、Oswald、Lobster、Anton、Courier Prime、'
                    'Quicksand、Space Grotesk、Abril Fatface、'
                    'Dancing Script、Caveat、Press Start 2P',
              ),
            ],
            showSourceRow: true,
            showPackageList: true,
          ),
        ),
      ),
    );
  }

  void _openPrivacy(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const LightPage(
          child: _InfoPage(
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
  final List<(String, String)> sections;
  final bool showSourceRow;
  final bool showPackageList;

  const _InfoPage({
    required this.sections,
    this.showSourceRow = false,
    this.showPackageList = false,
  });

  @override
  Widget build(BuildContext context) {
    return SwipeBack(
      child: Scaffold(
        backgroundColor: kLBg,
        appBar: AppBar(backgroundColor: kLBg),
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
                // 清單頁會抓當下的佈景（InheritedTheme.capture）：
                // 這一頁包在 LightPage 裡，它就跟著是淺色的
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: '浮水印',
                  applicationVersion: appVersionTag,
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
    );
  }
}
