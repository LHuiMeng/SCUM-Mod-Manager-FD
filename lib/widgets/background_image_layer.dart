import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/scum_colors.dart';

/// 3c：自定义背景图渲染层。
///
/// 渲染策略：
/// - [imagePath] 为 null：渲染纯 `bgDark`（与 Mica/亚克力 fallback 一致）。
/// - [imagePath] 非 null：`Image.file` 平铺铺满 + 上面叠 65% 暗色蒙版
///   让前景内容仍清晰可读。
///
/// **滚动条铁律**：本 widget 不引入任何滚动条 —— 图片用 `BoxFit.cover` 一次性
/// 渲染（不缩放、不平移），超出部分裁掉。
///
/// **IO 优化**：build 不做 `File.existsSync()` 同步 IO（避免每次 build
/// 阻塞主线程）。文件删除后由 `Image.file` 内部异步处理，渲染失败时
/// Flutter 仅打印 debug 日志，不阻塞 UI。
class BackgroundImageLayer extends StatelessWidget {
  final String? imagePath;

  const BackgroundImageLayer({super.key, this.imagePath});

  @override
  Widget build(BuildContext context) {
    final colors = ScumColors.of(context);
    if (imagePath == null) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: Stack(
        children: [
          // 1. 原图铺满。BoxFit.cover 保证图片比例不变，超出窗口部分裁剪。
          // 文件被删 / IO 失败 → Image.file 内部异步报错，widget 自身仍渲染。
          Positioned.fill(
            child: Image.file(
              File(imagePath!),
              fit: BoxFit.cover,
              // 内存友好：屏幕外暂时不需要的图让 Flutter 缓存层处理。
              cacheWidth: 1920,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          // 2. 暗色蒙版：让前景 UI 内容（文字/卡片）仍清晰。
          // alpha 0.65 是经验值 —— 太透看不清前景，太暗又看不到图。
          Positioned.fill(
            child: Container(color: colors.bgDark.withValues(alpha: 0.65)),
          ),
        ],
      ),
    );
  }
}
