import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/sticker_store.dart';
import '../theme.dart';

/// 貼圖挑選：上排「我的貼圖」（收藏的圖片）、下排內建 Emoji。
///
/// 回傳一張透明背景的 PNG，取消回 null。挑到什麼由呼叫端決定要
/// 接去哪——製作浮水印那邊接成圖片浮水印，時間軸那邊接成一段素材。
/// 兩邊各寫一份的話，之後多加一顆 Emoji 就得改兩個地方
Future<Uint8List?> pickSticker(BuildContext context) async {
  var mine = await StickerStore.load();
  if (!context.mounted) return null;
  final typed = TextEditingController();
  final picked = await showModalBottomSheet<Uint8List>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.8,
    ),
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) {
        // 送出自己打的那顆：取第一個「使用者感知字符」——emoji 常是
        // 多個 code unit（膚色、組合旗），不能用 substring 硬切
        Future<void> useTyped() async {
          final t = typed.text.trim();
          if (t.isEmpty) return;
          final png = await StickerStore.renderEmoji(t.characters.first);
          if (png != null && context.mounted) Navigator.pop(context, png);
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '貼圖',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    // 把相簿裡的圖收進「我的貼圖」，之後一鍵就拿得到
                    TextButton.icon(
                      onPressed: () async {
                        final picked = await ImagePicker().pickImage(
                          source: ImageSource.gallery,
                        );
                        if (picked == null) return;
                        final bytes = await picked.readAsBytes();
                        await StickerStore.add(bytes);
                        mine = await StickerStore.load();
                        setSheet(() {});
                      },
                      icon: const Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 17,
                      ),
                      label: const Text(
                        '從相簿加入貼圖',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (mine.isNotEmpty) ...[
                          const Padding(
                            padding: EdgeInsets.fromLTRB(2, 4, 2, 8),
                            child: Text(
                              '我的貼圖（長按移除）',
                              style: TextStyle(fontSize: 11, color: kTextDim),
                            ),
                          ),
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 5,
                                  mainAxisSpacing: 8,
                                  crossAxisSpacing: 8,
                                ),
                            itemCount: mine.length,
                            itemBuilder: (context, i) => InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () => Navigator.pop(context, mine[i]),
                              onLongPress: () async {
                                await StickerStore.removeAt(i);
                                mine = await StickerStore.load();
                                setSheet(() {});
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: kClipBorder),
                                ),
                                clipBehavior: Clip.antiAlias,
                                padding: const EdgeInsets.all(4),
                                child: Image.memory(
                                  mine[i],
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],
                        const Padding(
                          padding: EdgeInsets.fromLTRB(2, 0, 2, 8),
                          child: Text(
                            'Emoji',
                            style: TextStyle(fontSize: 11, color: kTextDim),
                          ),
                        ),
                        // 自己打：內建的 64 顆只是常用款，想要的不在裡面
                        // 就直接輸入（手機鍵盤的 emoji 面板什麼都有）。
                        // 打字、貼上都行，取第一個字符畫成貼圖
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: typed,
                                  decoration: const InputDecoration(
                                    hintText: '輸入任何 Emoji，例如 🐧',
                                    isDense: true,
                                    hintStyle: TextStyle(fontSize: 12.5),
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                  ),
                                  style: const TextStyle(fontSize: 18),
                                  textInputAction: TextInputAction.done,
                                  // 打完就變色可按，不用先猜按鈕在不在
                                  onChanged: (_) => setSheet(() {}),
                                  onSubmitted: (_) => useTyped(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: typed.text.trim().isEmpty
                                    ? null
                                    : useTyped,
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size(64, 40),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                child: const Text(
                                  '加入',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 6,
                                mainAxisSpacing: 6,
                                crossAxisSpacing: 6,
                              ),
                          itemCount: StickerStore.emojis.length,
                          itemBuilder: (context, i) {
                            final e = StickerStore.emojis[i];
                            return InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () async {
                                final png = await StickerStore.renderEmoji(e);
                                if (png != null && context.mounted) {
                                  Navigator.pop(context, png);
                                }
                              },
                              child: Center(
                                child: Text(
                                  e,
                                  style: const TextStyle(fontSize: 28),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
  typed.dispose();
  return picked;
}
