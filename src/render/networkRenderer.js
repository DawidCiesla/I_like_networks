import { getIncomePerSecond, getThroughputMbps, getUtilization } from '../simulation/model.js';

const CLIENT = { x: -315, y: 150, w: 112, h: 132 };
const SERVER = { x: 285, y: -145, w: 126, h: 126 };

const ROUTE = [
  { x: CLIENT.x + 57, y: 150 },
  { x: -122, y: 150 },
  { x: -78, y: 106 },
  { x: -78, y: -145 },
  { x: SERVER.x - 66, y: -145 },
];

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

function routeMetrics(points) {
  const segments = [];
  let total = 0;
  for (let i = 0; i < points.length - 1; i += 1) {
    const a = points[i];
    const b = points[i + 1];
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length = Math.hypot(dx, dy);
    segments.push({ a, b, dx, dy, length, start: total });
    total += length;
  }
  return { segments, total };
}

const ROUTE_METRICS = routeMetrics(ROUTE);

function pointOnRoute(distance) {
  const wrapped = ((distance % ROUTE_METRICS.total) + ROUTE_METRICS.total) % ROUTE_METRICS.total;
  const segment = ROUTE_METRICS.segments.find((item) => wrapped <= item.start + item.length) ?? ROUTE_METRICS.segments.at(-1);
  const local = clamp((wrapped - segment.start) / segment.length, 0, 1);
  const tangentLength = Math.max(1, segment.length);
  return {
    x: segment.a.x + segment.dx * local,
    y: segment.a.y + segment.dy * local,
    tx: segment.dx / tangentLength,
    ty: segment.dy / tangentLength,
  };
}

export class NetworkRenderer {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.ctx.imageSmoothingEnabled = false;
    this.dpr = Math.min(window.devicePixelRatio || 1, 2);
    this.camera = { x: 0, y: 0, zoom: 1 };
    this.pointer = { dragging: false, x: 0, y: 0, startX: 0, startY: 0 };
    this.selectedNode = null;
    this.time = 0;
    this.#bindInput();
    this.resize();
  }

  resize() {
    const rect = this.canvas.getBoundingClientRect();
    this.canvas.width = Math.max(1, Math.floor(rect.width * this.dpr));
    this.canvas.height = Math.max(1, Math.floor(rect.height * this.dpr));
    this.ctx.imageSmoothingEnabled = false;
  }

  #bindInput() {
    this.canvas.addEventListener('pointerdown', (event) => {
      this.pointer.dragging = true;
      this.pointer.x = event.clientX;
      this.pointer.y = event.clientY;
      this.pointer.startX = event.clientX;
      this.pointer.startY = event.clientY;
      this.canvas.setPointerCapture(event.pointerId);
    });

    this.canvas.addEventListener('pointermove', (event) => {
      if (!this.pointer.dragging) return;
      this.camera.x += (event.clientX - this.pointer.x) / this.camera.zoom;
      this.camera.y += (event.clientY - this.pointer.y) / this.camera.zoom;
      this.pointer.x = event.clientX;
      this.pointer.y = event.clientY;
    });

    this.canvas.addEventListener('pointerup', (event) => {
      const moved = Math.hypot(event.clientX - this.pointer.startX, event.clientY - this.pointer.startY);
      this.pointer.dragging = false;
      if (moved < 4) this.#selectAt(event.clientX, event.clientY);
    });

    this.canvas.addEventListener('wheel', (event) => {
      event.preventDefault();
      const factor = event.deltaY > 0 ? 0.9 : 1.1;
      this.camera.zoom = clamp(this.camera.zoom * factor, 0.55, 2.2);
    }, { passive: false });

    window.addEventListener('resize', () => this.resize());
  }

  #screenToWorld(clientX, clientY) {
    const rect = this.canvas.getBoundingClientRect();
    const x = clientX - rect.left - rect.width / 2;
    const y = clientY - rect.top - rect.height / 2;
    return {
      x: x / this.camera.zoom - this.camera.x,
      y: y / this.camera.zoom - this.camera.y,
    };
  }

  #selectAt(clientX, clientY) {
    const point = this.#screenToWorld(clientX, clientY);
    const hit = (node) => (
      point.x >= node.x - node.w / 2 &&
      point.x <= node.x + node.w / 2 &&
      point.y >= node.y - node.h / 2 &&
      point.y <= node.y + node.h / 2
    );
    this.selectedNode = hit(CLIENT) ? 'client' : hit(SERVER) ? 'server' : null;
  }

  render(state, deltaSeconds) {
    this.time += deltaSeconds;
    const ctx = this.ctx;
    const width = this.canvas.width / this.dpr;
    const height = this.canvas.height / this.dpr;

    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, width, height);
    this.#drawBackground(ctx, width, height);

    ctx.save();
    ctx.translate(width / 2, height / 2);
    ctx.scale(this.camera.zoom, this.camera.zoom);
    ctx.translate(this.camera.x, this.camera.y);

    if (state.linkBuilt) this.#drawActiveRoute(ctx, state);
    else this.#drawGhostRoute(ctx);

    this.#drawClient(ctx, state);
    this.#drawServer(ctx, state);

    if (state.linkBuilt) {
      this.#drawRelay(ctx, pointOnRoute(ROUTE_METRICS.total * 0.27), state.link.capacityMbps);
      this.#drawRelay(ctx, pointOnRoute(ROUTE_METRICS.total * 0.70), state.link.capacityMbps);
      this.#drawRevenuePulse(ctx, state);
    }

    ctx.restore();
  }

  #drawBackground(ctx, width, height) {
    ctx.fillStyle = '#1a1a1a';
    ctx.fillRect(0, 0, width, height);

    const spacing = 22;
    const offsetX = ((this.camera.x * this.camera.zoom) % spacing + spacing) % spacing;
    const offsetY = ((this.camera.y * this.camera.zoom) % spacing + spacing) % spacing;

    ctx.fillStyle = '#242424';
    for (let x = offsetX; x < width; x += spacing) {
      for (let y = offsetY; y < height; y += spacing) {
        const px = Math.round(x);
        const py = Math.round(y);
        ctx.fillRect(px - 2, py, 5, 1);
        ctx.fillRect(px, py - 2, 1, 5);
      }
    }

    ctx.fillStyle = 'rgba(52,52,52,.45)';
    for (let x = offsetX + spacing / 2; x < width; x += spacing * 2) {
      for (let y = offsetY + spacing / 2; y < height; y += spacing * 2) {
        ctx.fillRect(Math.round(x), Math.round(y), 1, 1);
      }
    }
  }

  #traceRoute(ctx) {
    ctx.beginPath();
    ctx.moveTo(ROUTE[0].x, ROUTE[0].y);
    for (let i = 1; i < ROUTE.length; i += 1) ctx.lineTo(ROUTE[i].x, ROUTE[i].y);
  }

  #drawGhostRoute(ctx) {
    ctx.save();
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.setLineDash([5, 7]);
    ctx.strokeStyle = '#393939';
    ctx.lineWidth = 12;
    this.#traceRoute(ctx);
    ctx.stroke();
    ctx.strokeStyle = '#676767';
    ctx.lineWidth = 2;
    this.#traceRoute(ctx);
    ctx.stroke();
    ctx.setLineDash([]);
    this.#drawTrackTies(ctx, '#4a4a4a', 16, 8);
    ctx.restore();
  }

  #drawActiveRoute(ctx, state) {
    const utilization = getUtilization(state);
    const glow = clamp(utilization, 0, 1);

    ctx.save();
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';

    ctx.strokeStyle = '#03111b';
    ctx.lineWidth = 16;
    this.#traceRoute(ctx);
    ctx.stroke();

    ctx.strokeStyle = '#005b92';
    ctx.lineWidth = 12;
    this.#traceRoute(ctx);
    ctx.stroke();

    ctx.strokeStyle = '#161616';
    ctx.lineWidth = 6;
    this.#traceRoute(ctx);
    ctx.stroke();

    ctx.strokeStyle = glow > 0.9 ? '#24c1ff' : '#008fdc';
    ctx.lineWidth = 2;
    this.#traceRoute(ctx);
    ctx.stroke();

    this.#drawTrackTies(ctx, glow > 0.9 ? '#00b8ff' : '#0076ba', 13, 11);
    this.#drawPackets(ctx, state);

    const labelPoint = pointOnRoute(ROUTE_METRICS.total * 0.48);
    this.#drawThroughputBadge(ctx, labelPoint.x, labelPoint.y, state);

    ctx.restore();
  }

  #drawTrackTies(ctx, color, every, width) {
    ctx.lineWidth = 2;
    ctx.strokeStyle = '#061018';
    for (let distance = 4; distance < ROUTE_METRICS.total; distance += every) {
      const point = pointOnRoute(distance);
      const nx = -point.ty;
      const ny = point.tx;
      ctx.beginPath();
      ctx.moveTo(point.x - nx * (width / 2 + 1), point.y - ny * (width / 2 + 1));
      ctx.lineTo(point.x + nx * (width / 2 + 1), point.y + ny * (width / 2 + 1));
      ctx.stroke();
    }

    ctx.lineWidth = 2;
    ctx.strokeStyle = color;
    for (let distance = 4; distance < ROUTE_METRICS.total; distance += every) {
      const point = pointOnRoute(distance);
      const nx = -point.ty;
      const ny = point.tx;
      ctx.beginPath();
      ctx.moveTo(point.x - nx * width / 2, point.y - ny * width / 2);
      ctx.lineTo(point.x + nx * width / 2, point.y + ny * width / 2);
      ctx.stroke();
    }
  }

  #drawPackets(ctx, state) {
    const throughput = getThroughputMbps(state);
    if (throughput <= 0) return;

    const count = Math.min(18, Math.max(3, Math.ceil(throughput / 2.5)));
    const speed = 35 + Math.min(throughput, 120) * 0.9;

    for (let i = 0; i < count; i += 1) {
      const distance = this.time * speed + (i / count) * ROUTE_METRICS.total;
      const point = pointOnRoute(distance);
      ctx.fillStyle = '#d9fbff';
      ctx.fillRect(Math.round(point.x) - 2, Math.round(point.y) - 2, 5, 5);
      ctx.fillStyle = '#00a8ef';
      ctx.fillRect(Math.round(point.x) - 1, Math.round(point.y) - 1, 3, 3);
    }
  }

  #drawThroughputBadge(ctx, x, y, state) {
    const throughput = getThroughputMbps(state);
    const label = `${throughput.toFixed(0)} Mb/s`;

    ctx.font = '10px "Lucida Console", monospace';
    const textWidth = ctx.measureText(label).width;
    const width = Math.ceil(textWidth + 15);

    ctx.fillStyle = '#151515';
    ctx.strokeStyle = '#565656';
    ctx.lineWidth = 2;
    ctx.fillRect(Math.round(x - width / 2), Math.round(y - 28), width, 20);
    ctx.strokeRect(Math.round(x - width / 2), Math.round(y - 28), width, 20);

    ctx.fillStyle = '#e5e5dc';
    ctx.textAlign = 'center';
    ctx.fillText(label, Math.round(x), Math.round(y - 14));
  }

  #drawRelay(ctx, point, capacity) {
    const x = Math.round(point.x);
    const y = Math.round(point.y);

    ctx.fillStyle = '#0d0d0d';
    ctx.strokeStyle = '#00a6ee';
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.arc(x, y, 17, 0, Math.PI * 2);
    ctx.fill();
    ctx.stroke();

    ctx.strokeStyle = '#005b92';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(x, y, 12, 0, Math.PI * 2);
    ctx.stroke();

    ctx.fillStyle = '#008ee1';
    ctx.fillRect(x - 7, y - 7, 14, 14);
    ctx.fillStyle = '#00588e';
    ctx.fillRect(x - 4, y - 4, 8, 8);

    const value = Math.round(capacity);
    ctx.font = '9px "Lucida Console", monospace';
    const width = value >= 100 ? 27 : 23;
    ctx.fillStyle = '#262626';
    ctx.strokeStyle = '#008ee1';
    ctx.lineWidth = 2;
    ctx.fillRect(x - width / 2, y - 31, width, 17);
    ctx.strokeRect(x - width / 2, y - 31, width, 17);
    ctx.fillStyle = '#f1f0e9';
    ctx.textAlign = 'center';
    ctx.fillText(String(value), x, y - 19);
  }

  #drawClient(ctx, state) {
    const x = Math.round(CLIENT.x);
    const y = Math.round(CLIENT.y);
    const selected = this.selectedNode === 'client';

    if (selected) this.#drawSelection(ctx, CLIENT, '#ee3154');

    ctx.fillStyle = '#050505';
    ctx.fillRect(x - 54, y - 64, 108, 128);

    ctx.fillStyle = '#f0efe8';
    ctx.fillRect(x - 48, y - 60, 96, 120);
    this.#pixelCutCorners(ctx, x - 48, y - 60, 96, 120, '#1a1a1a', 6);

    ctx.fillStyle = '#a7aaa6';
    ctx.fillRect(x - 41, y - 52, 82, 104);
    ctx.fillStyle = '#d6d5cd';
    ctx.fillRect(x - 35, y - 45, 70, 42);

    ctx.fillStyle = '#171717';
    ctx.fillRect(x - 27, y - 37, 54, 28);
    ctx.fillStyle = '#2a3538';
    ctx.fillRect(x - 20, y - 31, 40, 16);

    ctx.fillStyle = '#111';
    ctx.fillRect(x - 28, y + 10, 56, 31);
    ctx.fillStyle = '#242424';
    ctx.fillRect(x - 21, y + 16, 42, 18);

    ctx.fillStyle = '#e91e47';
    ctx.fillRect(x - 37, y + 45, 9, 5);
    ctx.fillStyle = '#555';
    ctx.fillRect(x - 18, y + 45, 20, 5);

    ctx.fillStyle = '#f1f0e8';
    ctx.font = '10px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText('CLIENT', x, y + 83);

    this.#drawNodeValue(ctx, x, y - 78, state.client.trafficMbps, '#e91e47');
  }

  #drawServer(ctx, state) {
    const x = Math.round(SERVER.x);
    const y = Math.round(SERVER.y);
    const selected = this.selectedNode === 'server';

    if (selected) this.#drawSelection(ctx, SERVER, '#10c927');

    ctx.fillStyle = '#050505';
    ctx.fillRect(x - 61, y - 61, 122, 122);

    ctx.fillStyle = '#f0efe8';
    ctx.fillRect(x - 56, y - 56, 112, 112);
    this.#pixelCutCorners(ctx, x - 56, y - 56, 112, 112, '#1a1a1a', 7);

    ctx.fillStyle = '#939792';
    ctx.fillRect(x - 47, y - 47, 94, 94);
    ctx.fillStyle = '#b9bbb5';
    ctx.fillRect(x - 39, y - 39, 78, 78);

    ctx.fillStyle = '#151515';
    ctx.fillRect(x - 27, y - 31, 54, 62);
    ctx.strokeStyle = '#efeee7';
    ctx.lineWidth = 3;
    ctx.strokeRect(x - 27, y - 31, 54, 62);

    for (let row = -20; row <= 18; row += 13) {
      ctx.fillStyle = '#59605d';
      ctx.fillRect(x - 17, y + row, 23, 5);
      ctx.fillStyle = '#16d633';
      ctx.fillRect(x + 12, y + row, 5, 5);
    }

    ctx.fillStyle = '#f1f0e8';
    ctx.font = '10px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText('SERVER', x, y + 79);

    this.#drawNodeValue(ctx, x, y - 75, state.server.capacityMbps, '#10c927');
  }

  #drawNodeValue(ctx, x, y, value, color) {
    const text = String(Math.round(value));
    const width = text.length >= 3 ? 31 : 26;

    ctx.fillStyle = '#202020';
    ctx.strokeStyle = color;
    ctx.lineWidth = 3;
    ctx.fillRect(x - width / 2, y - 10, width, 20);
    ctx.strokeRect(x - width / 2, y - 10, width, 20);

    ctx.fillStyle = '#efeee8';
    ctx.font = '10px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText(text, x, y + 4);
  }

  #drawRevenuePulse(ctx, state) {
    const income = getIncomePerSecond(state);
    if (income <= 0) return;

    const phase = this.time % 2.2;
    const rise = phase * 8;
    const alpha = clamp(1 - phase / 2.2, 0.15, 1);
    const x = SERVER.x + 78;
    const y = SERVER.y + 26 - rise;

    ctx.globalAlpha = alpha;
    ctx.fillStyle = '#ffe000';
    ctx.beginPath();
    ctx.arc(x, y, 9, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = '#594b00';
    ctx.beginPath();
    ctx.arc(x, y, 4, 0, Math.PI * 2);
    ctx.fill();

    ctx.fillStyle = '#b9ff8b';
    ctx.font = '12px "Lucida Console", monospace';
    ctx.textAlign = 'left';
    ctx.fillText(`+${income.toFixed(1)}`, x + 14, y + 4);
    ctx.globalAlpha = 1;
  }

  #drawSelection(ctx, node, color) {
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.setLineDash([4, 4]);
    ctx.strokeRect(
      Math.round(node.x - node.w / 2 - 8),
      Math.round(node.y - node.h / 2 - 8),
      node.w + 16,
      node.h + 16,
    );
    ctx.setLineDash([]);
  }

  #pixelCutCorners(ctx, x, y, width, height, color, size) {
    ctx.fillStyle = color;
    ctx.fillRect(x, y, size, size);
    ctx.fillRect(x + width - size, y, size, size);
    ctx.fillRect(x, y + height - size, size, size);
    ctx.fillRect(x + width - size, y + height - size, size, size);
  }
}
