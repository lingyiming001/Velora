# Velora 图标

2026-10-16，使用内置 image_gen 工具生成，参考根目录 Velora.png。
最终选用第一版，保留阴影；第二版未采用。
成品：App/Assets.xcassets/AppIcon.appiconset，10 个 macOS 规格。

## 最终采用的生成提示词

Use case: logo-brand. Asset type: production macOS app icon for Velora, square 1024x1024 PNG. Reference image: attached Velora.png; preserve its identity: a sculptural folded ribbon letter V, saturated indigo blue and violet on the left, pale lavender and subtle pink on right, dark indigo inner folded bottom, white softly dimensional rounded square tile. Create a refined faithful version of this mark as an actual icon asset, not a mockup. Front-on centered orthographic view, strong legibility at 16px, clean silhouette and slightly stronger contrast on pale right ribbon, restrained soft dimensional shading. White rounded square tile occupies 82% of canvas width, centered with equal margins; transparent canvas outside the rounded square and its very subtle shadow. The ribbon occupies roughly 64% of canvas width. No text, no additional symbols, no frame, no background scene, no checkerboard pixels. Keep the folded V geometry and original palette recognizable.

## 验证

已查看生成图；sips 确认最大规格 1024×1024、有 alpha；plutil 工程结构检查通过。
未构建或运行测试（用户负责测试）。原始参考图未覆盖。
