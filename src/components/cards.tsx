import React from "react";
import { cover, fmt } from "../api";
import type { VideoCard } from "../types";
import { IHeartF, IPlayF } from "../icons";
import { Img } from "./ui";

/* ——— 瀑布流卡片 ———
 *  列宽 193pt（428pt / 2 列 - 8pt 间距）。字号按这个宽度重算：
 *  标题 12.5px、角标 10px —— 原来是 11.5/9px，在 @3x 屏上明显偏小，
 *  也不符合 iOS 正文最小 11pt 的观感。角标内边距同步放宽，不再挤成一团。
 */
export function WaterfallCard({ v, onOpen }: { v: VideoCard; onOpen: () => void }) {
  const ratio = 1.32;
  return (
    <button onClick={onOpen}
      className="relative w-full overflow-hidden text-left bg-s1 elev-1 pressable block rounded-(--r-md)"
      style={{ paddingTop: `${ratio * 100}%` }}>
      <Img src={v.cover} />
      <div className="absolute inset-x-0 bottom-0 h-3/5 bg-gradient-to-t from-black/85 via-black/30 to-transparent" />
      <span className="absolute top-2 left-2 px-2 py-1 rounded-md text-[10px] font-bold brand-grad elev-1">
        {v.is_finished ? "已完结" : `更新至${v.episode_count}集`}
      </span>
      <span className="absolute top-2 right-2 flex items-center gap-0.5 px-2 py-1 rounded-md bg-black/45 backdrop-blur-sm text-[10px] font-semibold text-white/90">
        <IPlayF size={10} />{fmt(v.hot)}
      </span>
      <div className="absolute inset-x-0 bottom-0 p-2.5">
        <div className="text-[12.5px] font-medium text-white leading-snug clamp-2 tsh">{v.title}</div>
        <div className="flex items-center justify-between mt-1.5">
          <span className="text-[10.5px] text-white/65 truncate max-w-[60%]">{v.author?.name || "黄果短剧"}</span>
          <span className="flex items-center gap-0.5 text-[10.5px] text-white/75"><IHeartF size={11} className="text-white/70" />{fmt(v.like_count)}</span>
        </div>
      </div>
    </button>
  );
}

/* ——— 近无缝瀑布流 ———
 *  移动端固定 2 列：428pt 宽下每列约 193pt（扣 16pt gap），
 *  3:4 封面出图 193×254pt，正好是 iPhone 上刷剧单的舒适尺寸。
 *  原来 gap-1（4pt）两列贴得太紧，改为 gap-2（8pt），列间距才和有边距的页面呼吸位一致。
 */
export function Masonry({ videos, onOpen, wide = false, gap = "gap-2" }: {
  videos: VideoCard[]; onOpen: (v: VideoCard) => void; wide?: boolean; gap?: string;
}) {
  const mb = gap === "gap-2" ? "mb-2" : "mb-1.5";
  return (
    <div className={`${wide ? "columns-3 xl:columns-4" : "columns-2"} ${gap} [column-fill:balance]`}>
      {videos.map((v) => (
        <div key={v.id} className={`break-inside-avoid ${mb}`}>
          <WaterfallCard v={v} onOpen={() => onOpen(v)} />
        </div>
      ))}
    </div>
  );
}

/* ——— 分类横向卡片 ———
 *  宽 112pt：iPhone 13 Pro Max 逻辑宽 428pt，扣掉左右 16pt 边距剩 396pt，
 *  能露出 3.5 张（半张露边提示可横滑）。原来 104pt 会露出 3.8 张，
 *  边缘那张被切得只剩一条，看起来像渲染错误。 */
export function RowCard({ v, onOpen }: { v: VideoCard; onOpen: () => void }) {
  return (
    <button onClick={onOpen} className="w-[112px] shrink-0 text-left snap-start pressable group">
      <div className="relative w-full rounded-(--r-sm) overflow-hidden bg-s1 elev-1" style={{ paddingTop: "133%" }}>
        <Img src={v.cover} />
        <div className="absolute inset-x-0 bottom-0 h-1/2 bg-gradient-to-t from-black/75 to-transparent" />
        <span className="absolute top-1.5 left-1.5 px-1.5 py-0.5 rounded-md text-[8.5px] font-bold brand-grad">
          {v.is_finished ? "完结" : `${v.episode_count}集`}
        </span>
        <span className="absolute bottom-1.5 right-1.5 flex items-center gap-0.5 text-[9px] font-semibold text-white/90 tsh"><IPlayF size={9} />{fmt(v.hot)}</span>
      </div>
      <div className="mt-1.5 text-[11.5px] font-medium text-on clamp-1 leading-tight">{v.title}</div>
      <div className="text-[10px] text-mut clamp-1 mt-0.5">{v.tags?.slice(0, 2).join(" · ")}</div>
    </button>
  );
}

/* ——— 排行榜条目 ——— */
export function RankRow({ item, onOpen, metricMax }: {
  item: { rank: number; video_id: number; title: string; cover: string; tags: string[]; score: number; metric_value: number; metric_label: string };
  onOpen: () => void; metricMax: number;
}) {
  const i = item.rank - 1;
  return (
    <button onClick={onOpen}
      className={`w-full flex items-center gap-3 p-2.5 rounded-(--r-md) text-left mb-2 pressable a-rise ${i < 3 ? "bg-s3" : "bg-s2"}`}
      style={{ animationDelay: `${Math.min(i * 35, 300)}ms` }}>
      <span className={`w-7 h-7 rounded-full flex items-center justify-center text-[13px] font-bold shrink-0 tabular-nums ${i === 0 ? "bg-primary text-on-primary" : i < 3 ? "tonal" : "text-dim"}`}>{item.rank}</span>
      <div className="relative w-[52px] h-[68px] rounded-lg overflow-hidden bg-s3 shrink-0">
        <Img src={item.cover} />
      </div>
      <div className="flex-1 min-w-0">
        <div className="text-[12.5px] font-medium text-on clamp-2 leading-snug">{item.title}</div>
        <div className="flex items-center gap-2 mt-1.5">
          <span className="text-[10px] text-mut truncate">{item.tags?.slice(0, 2).join(" · ")}</span>
          <span className="flex items-center gap-0.5 text-[10px] font-bold text-primary">{fmt(item.metric_value)}</span>
        </div>
        <div className="mt-1.5 h-[3px] rounded-full bg-s4 overflow-hidden">
          <div className="h-full rounded-full bg-primary" style={{ width: `${Math.max(6, Math.round((item.metric_value / Math.max(1, metricMax)) * 100))}%` }} />
        </div>
      </div>
    </button>
  );
}