/**
 * Shared geometry / type scale for media list rows and video cards.
 * Keep History / Download / Queue / VideoMediaCard aligned.
 */
export const MEDIA_CARD_RADIUS: number = 12;
export const MEDIA_THUMB_RADIUS: number = 8;
export const MEDIA_LIST_THUMB_WIDTH: number = 160;
export const MEDIA_LIST_THUMB_HEIGHT: number = 90;
export const MEDIA_LIST_THUMB_GAP: number = 12;
export const MEDIA_TITLE_SIZE: number = 14;
export const MEDIA_TITLE_LINE_HEIGHT: number = 18;
export const MEDIA_META_SIZE: number = 12;
/** 信息行行高：网格卡片按它给作者行/统计行留固定高度，卡片才等高。 */
export const MEDIA_META_LINE_HEIGHT: number = 16;
/** 网格卡标题块固定高度（标题最多 2 行，短标题也占满，杜绝同行两卡高低不齐）。 */
export const MEDIA_GRID_TITLE_BLOCK_HEIGHT: number = MEDIA_TITLE_LINE_HEIGHT * 2;
export const MEDIA_CARD_SHADOW_RADIUS: number = 4;
export const MEDIA_CARD_SHADOW_OFFSET_Y: number = 2;
/** Radius for section card containers (options groups, about cards, log panels). */
export const SECTION_CARD_RADIUS: number = 16;
/** HDS 单行标题栏高度；浮动标题栏布局时用于内容区顶部预留。 */
export const TITLE_BAR_HEIGHT: number = 56;
