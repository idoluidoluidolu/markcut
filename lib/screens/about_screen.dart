import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'playback_test_screen.dart';

/// 原始碼位置（GPL 要求提供取得方式）
const kSourceUrl = 'https://github.com/idoluidoluidolu/markcut';
const kAppVersion = '1.0.0';

/// 開發者資訊：改這裡就會顯示在「關於」頁
const kDeveloperName = '（你的名字或工作室）';
const kDeveloperIntro = '（在這裡寫關於你的介紹、做這個 App 的緣由、'
    '或想對使用者說的話。）';
const kContact = '（聯絡信箱或社群連結）';

/// 關於：版本、開源授權（GPL v3）、第三方元件與字型
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Widget _section(String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: kText)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _body(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12.5, color: kTextDim, height: 1.6)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('關於 浮水印')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: kPanelHi,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.branding_watermark,
                      size: 28, color: kAmber),
                ),
                const SizedBox(height: 10),
                const Text('浮水印',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1)),
                const SizedBox(height: 2),
                const Text('版本 $kAppVersion',
                    style: TextStyle(fontSize: 12, color: kTextDim)),
                const SizedBox(height: 20),
              ],
            ),
          ),
          _section('關於作者', [
            _body(kDeveloperName),
            _body(kDeveloperIntro),
            const SizedBox(height: 2),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () async {
                await Clipboard.setData(
                    const ClipboardData(text: kContact));
                if (context.mounted) showHint(context, '已複製聯絡方式');
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 9),
                decoration: BoxDecoration(
                  color: kPanelHi,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: kClipBorder),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.alternate_email,
                        size: 15, color: kAmber),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(kContact,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5, color: kText)),
                    ),
                    const Icon(Icons.copy, size: 14, color: kTextDim),
                  ],
                ),
              ),
            ),
          ]),
          _section('開源授權', [
            _body('浮水印 是自由軟體，依 GNU 通用公共授權條款第三版'
                '（GPL v3）或後續版本散布。\n\n'
                '你可以自由使用、修改與再散布本程式，但衍生作品必須'
                '以相同授權釋出並公開原始碼。本程式不提供任何擔保。'),
            const SizedBox(height: 4),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () async {
                await Clipboard.setData(
                    const ClipboardData(text: kSourceUrl));
                if (context.mounted) {
                  showHint(context, '已複製原始碼網址');
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 9),
                decoration: BoxDecoration(
                  color: kPanelHi,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: kClipBorder),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.code, size: 15, color: kAmber),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(kSourceUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5, color: kText)),
                    ),
                    const Icon(Icons.copy,
                        size: 14, color: kTextDim),
                  ],
                ),
              ),
            ),
          ]),
          _section('影音處理', [
            _body('影音處理由 FFmpeg（LGPL v2.1+）與 media_kit 提供，'
                'H.264 編碼使用裝置的硬體編碼器。\n'
                'FFmpeg 為其各自作者所有，詳見 ffmpeg.org。'),
          ]),
          _section('內建字型（SIL Open Font License 1.1）', [
            _body('思源黑體、思源宋體 — Google / Adobe\n'
                'jf open 粉圓 — justfont\n'
                'LXGW 文楷 TC — 落霞孤鶩\n'
                '朱古力黑體 — Chocolate Classical Sans\n'
                'Montserrat、Playfair Display、Pacifico、'
                'Bebas Neue、Oswald、Lobster、Anton、Courier Prime'),
          ]),
          _section('隱私', [
            _body('所有影片與照片都在你的裝置上處理，'
                '浮水印 不會上傳、不會蒐集個人資料，也沒有帳號系統。'),
          ]),
          const SizedBox(height: 4),
          OutlinedButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: '浮水印',
              applicationVersion: kAppVersion,
              applicationLegalese: '依 GPL v3 散布',
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              side: const BorderSide(color: kClipBorder),
              foregroundColor: kText,
            ),
            child: const Text('第三方套件授權清單',
                style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(height: 16),
          // 效能檢測：畫面會出現 UI/Raster 圖表，卡頓時截圖回報用
          ValueListenableBuilder<bool>(
            valueListenable: kPerfOverlay,
            builder: (context, v, _) => Row(
              children: [
                const Expanded(
                  child: Text('效能檢測模式（除錯用）',
                      style: TextStyle(fontSize: 12.5, color: kTextDim)),
                ),
                Switch(
                    value: v, onChanged: (nv) => kPerfOverlay.value = nv),
              ],
            ),
          ),
          // 純播放測試：切分卡頓是套件/裝置問題還是編輯器問題
          TextButton(
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const PlaybackTestScreen())),
            style: TextButton.styleFrom(foregroundColor: kTextDim),
            child: const Text('影片純播放測試（除錯用）',
                style: TextStyle(fontSize: 12.5)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
