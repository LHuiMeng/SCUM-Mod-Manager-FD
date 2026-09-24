/// 拼音检索工具 —— 搜索框支持汉字全拼 / 首字母匹配（大小写不敏感）。
///
/// 场景：mod 名称多为英文文件名，但「备注/描述」常含中文；用户输入
/// `beibao` 或 `bb` 也能命中「背包」相关的中文备注。
///
/// 性能：只在目标文本含汉字时才做拼音转换（英文名称直接跳过），
/// 避免每个按键都对整列做无谓转换。
library;

import 'package:lpinyin/lpinyin.dart';

class PinyinSearch {
  /// 是否包含汉字（CJK 统一表意文字）。
  static bool _hasCjk(String s) => s.contains(RegExp(r'[\u4e00-\u9fff]'));

  /// 全拼（小写、无音调、无分隔）。非汉字原样保留。
  static String full(String text) => PinyinHelper.getPinyin(
        text,
        separator: '',
        format: PinyinFormat.WITHOUT_TONE,
      ).toLowerCase();

  /// 首字母（小写）。非汉字原样保留（英文名可直接匹配首字母串）。
  static String initials(String text) =>
      PinyinHelper.getShortPinyin(text).toLowerCase();

  /// 是否命中：原文包含 / 全拼包含 / 首字母包含（查询本身也转拼音再比对）。
  static bool matches(String haystack, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final h = haystack.toLowerCase();
    if (h.contains(q)) return true;
    // 双方都不含汉字 → 拼音转换没有意义，直接结束。
    if (!_hasCjk(haystack) && !_hasCjk(query)) return false;
    final hFull = full(haystack);
    final hInit = initials(haystack);
    if (hFull.contains(q) || hInit.contains(q)) return true;
    // 查询本身是汉字（如输入「背包」）→ 转成拼音再比对。
    if (_hasCjk(query)) {
      final qFull = full(q);
      final qInit = initials(q);
      if (hFull.contains(qFull) || hInit.contains(qInit)) return true;
    }
    return false;
  }
}