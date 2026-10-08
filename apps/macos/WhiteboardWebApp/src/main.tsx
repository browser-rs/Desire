import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import dagre from "dagre";

// MARK: - 类型（桥协议与 Swift 侧 WhiteboardSpec 对齐）

interface Block {
  type: string;
  title?: string;
  content: string;
  height?: number;
}
interface Spec {
  title: string;
  blocks: Block[];
}

declare global {
  interface Window {
    webkit?: { messageHandlers: Record<string, { postMessage: (m: unknown) => void }> };
    __pendingSpec?: Spec;
    echarts?: any;
    mermaid?: any;
    renderBoard?: (spec: Spec) => void;
    __editing?: () => number;
    __startEdit?: (idx: number) => void;
    __lastRenderStats?: { rendered: number; errors: string[]; at: number };
  }
}

function postEdit(payload: Record<string, unknown>) {
  try {
    window.webkit?.messageHandlers.whiteboardEdit.postMessage(payload);
  } catch {}
}
function postRender(rendered: number, errors: string[]) {
  window.__lastRenderStats = { rendered, errors, at: Date.now() };
  try {
    window.webkit?.messageHandlers.whiteboardRender.postMessage({ rendered, errors });
  } catch {}
}
function postHeight(h: number) {
  try {
    window.webkit?.messageHandlers.whiteboardLayout.postMessage({ height: Math.ceil(h) + 2 });
  } catch {}
}
function postLink(url: string) {
  try {
    window.webkit?.messageHandlers.whiteboardLink.postMessage({ url });
  } catch {}
}

// MARK: - note 的 mini markdown（含 ``` 围栏代码块）

function miniMarkdown(text: string): string {
  const blocks: string[] = [];
  const src = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const fenced = src.replace(/```([a-zA-Z0-9_]*)\n([\s\S]*?)```/g, (_m, _lang, code) => {
    blocks.push(`<pre><code>${code}</code></pre>`);
    return `\u000BBLOCK${blocks.length - 1}\u000B`;
  });
  let out = fenced
    .replace(/^### (.*)$/gm, "<h3>$1</h3>")
    .replace(/^## (.*)$/gm, "<h2>$1</h2>")
    .replace(/^# (.*)$/gm, "<h1>$1</h1>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a class="note-link" data-href="$2">$1</a>')
    .replace(/^- (.*)$/gm, "• $1");
  out = out.replace(/\u000BBLOCK(\d+)\u000B/g, (_m, i) => blocks[+i]);
  return out;
}

// MARK: - 静态 SVG 图渲染（v8：dagre 布局 + 自绘节点/曲线——零运行时测量，
// 离屏 webview 100% 可靠。ReactFlow/markmap 的容器测量在离屏环境不可靠，
// 详见 CHANGELOG；交互式缩放平移是牺牲项，内容呈现优先可靠。）

/** 节点标签宽度估算（中文 15/字符、半角 8.5）。 */
function labelWidth(text: string): number {
  let w = 0;
  for (const ch of text) w += ch.charCodeAt(0) > 0x2e80 ? 15 : 8.5;
  return w;
}

const FLOW_PALETTE = ["#eef3fd", "#e5f4ee", "#fdf3e0", "#fdeef6", "#f0ecfc", "#e6f6f9"];
const FLOW_STROKE = ["#7ea6e8", "#4cc38a", "#e8a13a", "#ec6ad1", "#8b7cf6", "#45c4d8"];

interface FlowSpec {
  direction?: "LR" | "TB";
  nodes: { id: string; label: string; shape?: string; color?: string }[];
  edges: { from: string; to: string; label?: string }[];
}

function FlowSVG({ spec }: { spec: FlowSpec }) {
  const layout = useMemo(() => {
    const dir = spec.direction === "TB" ? "TB" : "LR";
    const g = new dagre.graphlib.Graph();
    g.setGraph({ rankdir: dir, nodesep: 34, ranksep: 60, marginx: 18, marginy: 18 });
    g.setDefaultEdgeLabel(() => ({}));
    const sizeOf = (n: { label: string }) => ({ width: labelWidth(n.label) + 36, height: 40 });
    for (const n of spec.nodes) g.setNode(n.id, sizeOf(n));
    for (const e of spec.edges) {
      if (spec.nodes.some((n) => n.id === e.from) && spec.nodes.some((n) => n.id === e.to)) {
        g.setEdge(e.from, e.to);
      }
    }
    dagre.layout(g);
    const pos = new Map<string, { x: number; y: number; w: number; h: number }>();
    for (const n of spec.nodes) {
      const gn = g.node(n.id);
      const sz = sizeOf(n);
      pos.set(n.id, { x: gn.x - sz.width / 2, y: gn.y - sz.height / 2, w: sz.width, h: sz.height });
    }
    return { dir, pos, gw: (g.graph().width as number) || 400, gh: (g.graph().height as number) || 200 };
  }, [spec]);

  const body = spec.nodes.map((n, i) => {
    const p = layout.pos.get(n.id)!;
    const fill = FLOW_PALETTE[i % FLOW_PALETTE.length];
    const stroke = FLOW_STROKE[i % FLOW_STROKE.length];
    return (
      <g key={n.id}>
        <rect
          x={p.x} y={p.y} width={p.w} height={p.h} rx={10}
          fill={fill} stroke={stroke} strokeWidth={1.5}
          style={{ filter: "drop-shadow(0 2px 3px rgba(15,23,42,0.10))" }}
        />
        <text
          x={p.x + p.w / 2} y={p.y + p.h / 2}
          textAnchor="middle" dominantBaseline="central"
          fontSize={13} fontWeight={500} fill="#1f2937"
        >
          {n.label}
        </text>
      </g>
    );
  });

  const edges = spec.edges.map((e, i) => {
    const a = layout.pos.get(e.from);
    const b = layout.pos.get(e.to);
    if (!a || !b) return null;
    const LR = layout.dir === "LR";
    const ax = LR ? a.x + a.w : a.x + a.w / 2;
    const ay = LR ? a.y + a.h / 2 : a.y + a.h;
    const bx = LR ? b.x : b.x + b.w / 2;
    const by = LR ? b.y + b.h / 2 : b.y;
    const mid = LR ? (ax + bx) / 2 : (ay + by) / 2;
    const d = LR
      ? `M ${ax} ${ay} C ${mid} ${ay}, ${mid} ${by}, ${bx} ${by}`
      : `M ${ax} ${ay} C ${ax} ${mid}, ${bx} ${mid}, ${bx} ${by}`;
    const lx = (ax + bx) / 2, ly = (ay + by) / 2;
    const lw = e.label ? labelWidth(e.label) : 0;
    return (
      <g key={i}>
        <path d={d} fill="none" stroke="#94a3b8" strokeWidth={1.6} markerEnd="url(#wb-arrow)" />
        {e.label ? (
          <g>
            <rect x={lx - lw / 2 - 6} y={ly - 11} width={lw + 12} height={22} rx={7}
                  fill="#ffffff" stroke="#e6e8ec" strokeWidth={1} />
            <text x={lx} y={ly} textAnchor="middle" dominantBaseline="central"
                  fontSize={11} fontWeight={500} fill="#475569">{e.label}</text>
          </g>
        ) : null}
      </g>
    );
  });

  return (
    <svg width="100%" viewBox={`0 0 ${layout.gw} ${layout.gh}`} style={{ display: "block", maxHeight: 460 }}>
      <defs>
        <marker id="wb-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
          <path d="M 0 0 L 10 5 L 0 10 z" fill="#94a3b8" />
        </marker>
      </defs>
      {edges}
      {body}
    </svg>
  );
}

// MARK: - 思维导图（缩进文本 → 横向树 SVG，分支彩色粗曲线）

interface MMNode { label: string; children: MMNode[] }

function parseMindmap(src: string): MMNode | null {
  const lines = src.split("\n").filter((l) => l.trim());
  if (!lines.length) return null;
  const root: MMNode = { label: lines[0].trim(), children: [] };
  const stack: { level: number; node: MMNode }[] = [{ level: -1, node: root }];
  for (let i = 1; i < lines.length; i++) {
    const m = lines[i].match(/^(\s*)(.*)$/);
    if (!m) continue;
    const level = Math.floor(m[1].replace(/\t/g, "  ").length / 2);
    const node: MMNode = { label: m[2].trim(), children: [] };
    while (stack.length && stack[stack.length - 1].level >= level) stack.pop();
    if (!stack.length) return null;
    stack[stack.length - 1].node.children.push(node);
    stack.push({ level, node });
  }
  return root;
}

const MM_COLORS = ["#4f7cf0", "#4cc38a", "#f5a623", "#ec6ad1", "#8b7cf6", "#45c4d8", "#e5484d", "#f0c000"];
const MM_NODE_H = 32, MM_GAP = 12, MM_LEVEL_W = 185;

function MindmapSVG({ content }: { content: string }) {
  const layout = useMemo(() => {
    const tree = parseMindmap(content);
    if (!tree) return null;
    const pos = new Map<MMNode, { x: number; y: number; w: number; depth: number }>();
    const heights = new Map<MMNode, number>();
    let maxDepth = 0;
    function measure(n: MMNode, depth: number): number {
      maxDepth = Math.max(maxDepth, depth);
      if (!n.children.length) {
        const h = MM_NODE_H + MM_GAP;
        heights.set(n, h);
        return h;
      }
      const h = Math.max(n.children.reduce((acc, c) => acc + measure(c, depth + 1), 0), MM_NODE_H + MM_GAP);
      heights.set(n, h);
      return h;
    }
    const totalH = measure(tree, 0);
    function place(n: MMNode, depth: number, yTop: number): void {
      const h = heights.get(n)!;
      const w = labelWidth(n.label) + 30;
      pos.set(n, { x: 18 + depth * MM_LEVEL_W, y: yTop + h / 2 - MM_NODE_H / 2, w, depth });
      let childTop = yTop;
      for (const c of n.children) {
        place(c, depth + 1, childTop);
        childTop += heights.get(c)!;
      }
    }
    place(tree, 0, 0);
    const svgW = 18 + (maxDepth + 1) * MM_LEVEL_W + 140;
    function maxDepthOf(n: MMNode, d = 0): number {
      return n.children.length ? Math.max(...n.children.map((c) => maxDepthOf(c, d + 1))) : d;
    }
    return { pos, tree, svgW, svgH: totalH + MM_GAP, svgW2: svgW, maxDepth: maxDepthOf(tree) };
  }, [content]);
  if (!layout) return <p className="wb-err">思维导图为空</p>;
  const { pos, tree, svgH } = layout;
  const svgW = layout.svgW;

  const branches: React.ReactNode[] = [];
  const nodesOut: React.ReactNode[] = [];
  const branchColor = new Map<MMNode, string>();
  tree.children.forEach((c, i) => branchColor.set(c, MM_COLORS[i % MM_COLORS.length]));
  function findParent(parent: MMNode, target: MMNode): MMNode | null {
    for (const c of parent.children) {
      if (c === target) return parent;
      const r = findParent(c, target);
      if (r) return r;
    }
    return null;
  }
  function topColor(n: MMNode): string {
    let cur = n, parent = findParent(tree, cur);
    while (parent && parent !== tree) { cur = parent; parent = findParent(tree, cur); }
    return branchColor.get(cur) || "#94a3b8";
  }
  function emit(n: MMNode) {
    const p = pos.get(n)!;
    if (n !== tree) {
      const parent = findParent(tree, n)!;
      const pp = pos.get(parent)!;
      const color = topColor(n);
      branches.push(
        <path
          key={`e-${p.depth}-${p.y}`}
          d={`M ${pp.x + pp.w} ${pp.y + MM_NODE_H / 2} C ${pp.x + pp.w + 55} ${pp.y + MM_NODE_H / 2}, ${p.x - 55} ${p.y + MM_NODE_H / 2}, ${p.x} ${p.y + MM_NODE_H / 2}`}
          fill="none" stroke={color} strokeWidth={2.4} opacity={0.85}
        />
      );
    }
    const isRoot = n === tree;
    const isL1 = !isRoot && findParent(tree, n) === tree;
    const color = isRoot ? "#f0b429" : isL1 ? branchColor.get(n)! : topColor(n);
    if (isRoot) {
      nodesOut.push(
        <g key={`n-root-${p.y}`}>
          <circle cx={p.x + 34} cy={p.y + MM_NODE_H / 2} r={30} fill={color}
                  style={{ filter: "drop-shadow(0 2px 4px rgba(15,23,42,0.18))" }} />
          <text x={p.x + 34} y={p.y + MM_NODE_H / 2} textAnchor="middle" dominantBaseline="central"
                fontSize={15} fontWeight={700} fill="#ffffff">{n.label}</text>
        </g>
      );
    } else {
      nodesOut.push(
        <g key={`n-${p.depth}-${p.y}`}>
          <rect
            x={p.x} y={p.y} width={p.w} height={MM_NODE_H} rx={isL1 ? 9 : 7}
            fill={isL1 ? color : "#ffffff"} stroke={isL1 ? color : "#d8dce4"} strokeWidth={1.2}
            style={{ filter: "drop-shadow(0 1px 2px rgba(15,23,42,0.10))" }}
          />
          <text
            x={p.x + p.w / 2} y={p.y + MM_NODE_H / 2}
            textAnchor="middle" dominantBaseline="central"
            fontSize={isL1 ? 12.5 : 11.5} fontWeight={isL1 ? 600 : 400}
            fill={isL1 ? "#ffffff" : "#374151"}
          >
            {n.label}
          </text>
        </g>
      );
    }
    n.children.forEach(emit);
  }
  emit(tree);

  return (
    <svg width="100%" viewBox={`0 0 ${svgW} ${svgH}`} style={{ display: "block", maxHeight: 560 }}>
      {branches}
      {nodesOut}
    </svg>
  );
}

// MARK: - Chart 块（echarts，宿主 script 提供 window.echarts）

function ChartView({ content, height }: { content: string; height?: number }) {
  const ref = useRef<HTMLDivElement | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    if (!ref.current) return;
    try {
      const option = JSON.parse(content);
      const chart = (window as any).echarts.init(ref.current);
      if (!option.color) {
        option.color = ["#4f7cf0", "#4cc38a", "#f5a623", "#ec6ad1", "#8b7cf6", "#45c4d8", "#e5484d"];
      }
      chart.setOption(option);
      const onResize = () => chart.resize();
      window.addEventListener("resize", onResize);
      return () => {
        window.removeEventListener("resize", onResize);
        try { chart.dispose(); } catch {}
      };
    } catch (e: any) {
      setErr(e?.message || String(e));
    }
  }, [content, height]);
  const h = height && isFinite(height) ? Math.min(Math.max(height, 120), 800) : 320;
  return err ? <p className="wb-err">图表渲染失败：{err}</p> : <div ref={ref} style={{ width: "100%", height: h }} />;
}

// MARK: - note / table

function NoteView({ content }: { content: string }) {
  const onClick = useCallback((ev: React.MouseEvent) => {
    const a = (ev.target as HTMLElement).closest?.("a.note-link") as HTMLElement | null;
    if (!a) return;
    ev.preventDefault();
    const href = a.getAttribute("data-href");
    if (href) postLink(href);
  }, []);
  return <div className="wb-note" onClick={onClick} dangerouslySetInnerHTML={{ __html: miniMarkdown(content) }} />;
}

function TableView({ content }: { content: string }) {
  const rows = content.trim().split("\n").filter((l) => l.trim());
  const cells = (row: string) =>
    row.replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
  return (
    <table className="wb-table">
      <tbody>
        {rows.map((row, ri) => {
          const cs = cells(row);
          if (cs.length && cs.every((c) => /^:?-+:?$/.test(c))) return null;
          return (
            <tr key={ri}>
              {cs.map((c, ci) => (ri === 0 ? <th key={ci}>{c}</th> : <td key={ci}>{c}</td>))}
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

// MARK: - mermaid 兜底（旧档 mermaid 块）

function MermaidView({ content, index }: { content: string; index: number }) {
  const ref = useRef<HTMLDivElement | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const out = await window.mermaid.render(`mmd-${index}-${Date.now()}`, content);
        if (!cancelled && ref.current) ref.current.innerHTML = out.svg;
      } catch (e: any) {
        if (!cancelled) setErr(e?.message || String(e));
      }
    })();
    return () => { cancelled = true; };
  }, [content, index]);
  return err ? <p className="wb-err">Mermaid 渲染失败：{err}</p> : <div className="wb-mermaid" ref={ref} />;
}

// MARK: - 块卡片

function BlockCard({
  block, index, count, editing,
  onStartEdit, onSaveEdit, onCancelEdit, onMove, onDelete, onRendered,
}: {
  block: Block; index: number; count: number; editing: boolean;
  onStartEdit: (i: number) => void;
  onSaveEdit: (i: number, content: string) => void;
  onCancelEdit: () => void;
  onMove: (i: number, delta: number) => void;
  onDelete: (i: number) => void;
  onRendered: (index: number, ok: boolean) => void;
}) {
  const [editText, setEditText] = useState(block.content);
  const bodyRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (editing) return;
    let cancelled = false;
    const t = setTimeout(() => {
      if (cancelled) return;
      const hasErr = !!bodyRef.current?.querySelector(".wb-err");
      onRendered(index, !hasErr);
    }, 60);
    return () => { cancelled = true; clearTimeout(t); };
  }, [block.content, editing]);

  useEffect(() => { setEditText(block.content); }, [editing, block.content]);

  return (
    <div
      className="wb-card"
      data-index={index}
      onDragOver={(ev) => {
        ev.preventDefault();
        ev.currentTarget.classList.add("wb-drop");
      }}
      onDragLeave={(ev) => ev.currentTarget.classList.remove("wb-drop")}
      onDrop={(ev) => {
        ev.preventDefault();
        ev.currentTarget.classList.remove("wb-drop");
        const from = parseInt(ev.dataTransfer.getData("text/wb-index") || "", 10);
        if (!isNaN(from) && from !== index) postEdit({ kind: "reorder", index: from, delta: index });
      }}
    >
      <div className="wb-card-head">
        <span
          className="wb-grip" title="拖动排序" draggable
          onDragStart={(ev) => {
            ev.dataTransfer.setData("text/wb-index", String(index));
            ev.dataTransfer.effectAllowed = "move";
            ev.currentTarget.closest(".wb-card")?.classList.add("wb-dragging");
          }}
          onDragEnd={() => {
            document.querySelectorAll(".wb-card").forEach((c) => c.classList.remove("wb-dragging", "wb-drop"));
          }}
        >
          ⠿
        </span>
        {block.title ? <span className="wb-card-title">{block.title}</span> : <span />}
        <span className="wb-tools">
          <button title="上移" onClick={() => onMove(index, -1)} disabled={index === 0}>↑</button>
          <button title="下移" onClick={() => onMove(index, 1)} disabled={index === count - 1}>↓</button>
          {block.type !== "image" ? <button title="编辑源码" onClick={() => onStartEdit(index)}>✎</button> : null}
          <button title="删除" onClick={() => onDelete(index)}>✕</button>
        </span>
      </div>
      {editing ? (
        <div>
          <textarea className="wb-editor" value={editText} onChange={(e) => setEditText(e.target.value)} autoFocus />
          <div className="wb-editor-actions">
            <button onClick={() => onSaveEdit(index, editText)}>保存</button>
            <button onClick={onCancelEdit}>取消</button>
          </div>
        </div>
      ) : (
        <div className="wb-body" ref={bodyRef}>
          {block.type === "flow" ? (
            <FlowSVG spec={safeParseFlow(block.content)} />
          ) : block.type === "mindmap" ? (
            <MindmapSVG content={block.content} />
          ) : block.type === "mermaid" ? (
            <MermaidView content={block.content} index={index} />
          ) : block.type === "chart" ? (
            <ChartView content={block.content} height={block.height} />
          ) : block.type === "note" ? (
            <NoteView content={block.content} />
          ) : block.type === "table" ? (
            <TableView content={block.content} />
          ) : block.type === "image" ? (
            /^data:image\//.test(block.content) ? (
              <div className="wb-image"><img src={block.content} alt={block.title || "image"} /></div>
            ) : (
              <p className="wb-err">Image block must be a data:image/ URI</p>
            )
          ) : (
            <p className="wb-err">未知块类型：{block.type}</p>
          )}
        </div>
      )}
    </div>
  );
}

function safeParseFlow(content: string): FlowSpec {
  try {
    const spec = JSON.parse(content) as FlowSpec;
    if (spec && Array.isArray(spec.nodes)) return spec;
  } catch {}
  return { nodes: [], edges: [] };
}

// MARK: - App（板状态 + 桥）

let pendingSpec: Spec | null = null;
window.renderBoard = (spec: Spec) => {
  pendingSpec = spec;
  window.dispatchEvent(new Event("wb-render"));
};

function App() {
  const [spec, setSpec] = useState<Spec>(() => window.__pendingSpec || { title: "白板", blocks: [] });
  const [editing, setEditing] = useState(-1);
  const doneRef = useRef<Map<number, boolean>>(new Map());
  const rootRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const onRender = () => {
      if (pendingSpec) {
        setSpec(pendingSpec);
        setEditing(-1);
        doneRef.current = new Map();
      }
    };
    window.addEventListener("wb-render", onRender);
    return () => window.removeEventListener("wb-render", onRender);
  }, []);

  useEffect(() => {
    if (!spec.blocks.length) {
      postRender(0, []);
      postHeight(rootRef.current?.scrollHeight || 40);
      return;
    }
    if (doneRef.current.size < spec.blocks.length) return;
    let rendered = 0;
    const errors: string[] = [];
    doneRef.current.forEach((ok, i) => {
      if (ok) rendered++;
      else errors.push(`block ${i + 1}`);
    });
    postRender(rendered, errors);
  }, [spec, doneRef.current.size]);

  useEffect(() => {
    const el = rootRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => postHeight(el.scrollHeight));
    ro.observe(el);
    postHeight(el.scrollHeight);
    return () => ro.disconnect();
  }, []);

  const onRendered = useCallback((index: number, ok: boolean) => {
    doneRef.current.set(index, ok);
    setDoneCount(doneRef.current.size);
  }, []);
  const [, setDoneCount] = useState(0);

  return (
    <div className="wb-root" ref={rootRef}>
      <div className="wb-boardtitle">{spec.title}</div>
      {spec.blocks.length === 0 ? (
        <div className="wb-empty">白板是空的——让智能体画点什么。</div>
      ) : (
        spec.blocks.map((block, i) => (
          <BlockCard
            key={i}
            block={block}
            index={i}
            count={spec.blocks.length}
            editing={editing === i}
            onStartEdit={setEditing}
            onSaveEdit={(i2, content) => postEdit({ kind: "edit", index: i2, content })}
            onCancelEdit={() => setEditing(-1)}
            onMove={(i2, delta) => postEdit({ kind: "move", index: i2, delta })}
            onDelete={(i2) => postEdit({ kind: "delete", index: i2 })}
            onRendered={onRendered}
          />
        ))
      )}
    </div>
  );
}

createRoot(document.getElementById("board")!).render(<App />);
