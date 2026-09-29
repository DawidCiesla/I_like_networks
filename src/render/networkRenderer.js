import {
  getIncomePerSecond,
  getPacketLossPercent,
  getQueueFillRatio,
  getThroughputMbps,
  getTotalDemandMbps,
} from '../simulation/model.js';

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

const DIRECT_CLIENT = { x: -315, y: 145, w: 100, h: 108 };
const DIRECT_SERVER = { x: 300, y: -135, w: 118, h: 118 };

const SWITCH = { x: 0, y: 0, w: 104, h: 76 };
const SERVER = { x: 345, y: 0, w: 118, h: 118 };
const CLIENT_POSITIONS = [
  { x: -355, y: -210 },
  { x: -355, y: -70 },
  { x: -355, y: 70 },
  { x: -355, y: 210 },
];

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
  return { points, segments, total };
}

function pointOnRoute(metrics, distance) {
  if (metrics.total <= 0) return { x: 0, y: 0, tx: 1, ty: 0 };
  const wrapped = ((distance % metrics.total) + metrics.total) % metrics.total;
  const segment = metrics.segments.find((item) => wrapped <= item.start + item.length) ?? metrics.segments.at(-1);
  const local = clamp((wrapped - segment.start) / segment.length, 0, 1);
  return {
    x: segment.a.x + segment.dx * local,
    y: segment.a.y + segment.dy * local,
    tx: segment.dx / Math.max(1, segment.length),
    ty: segment.dy / Math.max(1, segment.length),
  };
}

const DIRECT_ROUTE = routeMetrics([
  { x: DIRECT_CLIENT.x + 52, y: DIRECT_CLIENT.y },
  { x: -120, y: DIRECT_CLIENT.y },
  { x: -75, y: 100 },
  { x: -75, y: DIRECT_SERVER.y },
  { x: DIRECT_SERVER.x - 62, y: DIRECT_SERVER.y },
]);

const TRUNK_ROUTE = routeMetrics([
  { x: SWITCH.x + 54, y: 0 },
  { x: 175, y: 0 },
  { x: 225, y: -25 },
  { x: SERVER.x - 63, y: -25 },
  { x: SERVER.x - 63, y: 0 },
]);

function branchRoute(position) {
  return routeMetrics([
    { x: position.x + 45, y: position.y },
    { x: -210, y: position.y },
    { x: -135, y: position.y * 0.35 },
    { x: SWITCH.x - 55, y: 0 },
  ]);
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
      point.x >= node.x - node.w / 2
      && point.x <= node.x + node.w / 2
      && point.y >= node.y - node.h / 2
      && point.y <= node.y + node.h / 2
    );

    if (hit(SWITCH)) this.selectedNode = 'switch';
    else if (hit(SERVER) || hit(DIRECT_SERVER)) this.selectedNode = 'server';
    else this.selectedNode = null;
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

    if (state.switch.built) this.#drawSwitchedNetwork(ctx, state);
    else this.#drawDirectNetwork(ctx, state);

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
  }

  #drawDirectNetwork(ctx, state) {
    if (state.linkBuilt) {
      this.#drawRoute(ctx, DIRECT_ROUTE, '#008fdc', getThroughputMbps(state), false);
      this.#drawRouteBadge(ctx, DIRECT_ROUTE, `${getThroughputMbps(state).toFixed(0)} Mb/s`);
    } else {
      this.#drawGhostRoute(ctx, DIRECT_ROUTE);
    }

    this.#drawClient(ctx, DIRECT_CLIENT.x, DIRECT_CLIENT.y, 1, state.client.trafficMbps, true);
    this.#drawServer(ctx, DIRECT_SERVER.x, DIRECT_SERVER.y, state.server.capacityMbps);

    if (state.linkBuilt) this.#drawRevenuePulse(ctx, DIRECT_SERVER.x + 74, DIRECT_SERVER.y + 25, state);
  }

  #drawSwitchedNetwork(ctx, state) {
    const queueFill = getQueueFillRatio(state);
    const loss = getPacketLossPercent(state);

    for (let index = 0; index < state.client.count; index += 1) {
      const position = CLIENT_POSITIONS[index];
      const route = branchRoute(position);
      this.#drawRoute(ctx, route, '#d02be3', state.client.trafficMbps, false);
      this.#drawClient(ctx, position.x, position.y, index + 1, state.client.trafficMbps, false);
    }

    const trunkColor = loss > 0
      ? '#e91e47'
      : queueFill >= 0.5
        ? '#f4ca00'
        : '#0797ec';

    this.#drawRoute(ctx, TRUNK_ROUTE, trunkColor, getThroughputMbps(state), queueFill >= 0.9);
    this.#drawRouteBadge(ctx, TRUNK_ROUTE, `${getThroughputMbps(state).toFixed(0)} Mb/s`);

    this.#drawSwitch(ctx, state);
    this.#drawServer(ctx, SERVER.x, SERVER.y, state.server.capacityMbps);
    this.#drawQueue(ctx, state);
    this.#drawRevenuePulse(ctx, SERVER.x + 74, SERVER.y + 25, state);

    if (loss > 0) this.#drawDroppedPackets(ctx, state);
  }

  #traceRoute(ctx, metrics) {
    ctx.beginPath();
    ctx.moveTo(metrics.points[0].x, metrics.points[0].y);
    for (let i = 1; i < metrics.points.length; i += 1) {
      ctx.lineTo(metrics.points[i].x, metrics.points[i].y);
    }
  }

  #drawGhostRoute(ctx, metrics) {
    ctx.save();
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.setLineDash([5, 7]);
    ctx.strokeStyle = '#393939';
    ctx.lineWidth = 12;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();
    ctx.strokeStyle = '#676767';
    ctx.lineWidth = 2;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.restore();
  }

  #drawRoute(ctx, metrics, color, flowMbps, danger) {
    ctx.save();
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';

    ctx.strokeStyle = '#050505';
    ctx.lineWidth = 16;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    ctx.strokeStyle = color;
    ctx.lineWidth = danger ? 13 : 11;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    ctx.strokeStyle = '#171717';
    ctx.lineWidth = 6;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    this.#drawTrackTies(ctx, metrics, color);
    this.#drawPackets(ctx, metrics, flowMbps, color);

    ctx.restore();
  }

  #drawTrackTies(ctx, metrics, color) {
    for (let distance = 5; distance < metrics.total; distance += 14) {
      const point = pointOnRoute(metrics, distance);
      const nx = -point.ty;
      const ny = point.tx;

      ctx.strokeStyle = '#050505';
      ctx.lineWidth = 4;
      ctx.beginPath();
      ctx.moveTo(point.x - nx * 7, point.y - ny * 7);
      ctx.lineTo(point.x + nx * 7, point.y + ny * 7);
      ctx.stroke();

      ctx.strokeStyle = color;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(point.x - nx * 6, point.y - ny * 6);
      ctx.lineTo(point.x + nx * 6, point.y + ny * 6);
      ctx.stroke();
    }
  }

  #drawPackets(ctx, metrics, flowMbps, color) {
    if (flowMbps <= 0) return;

    const count = Math.min(14, Math.max(2, Math.ceil(flowMbps / 4)));
    const speed = 30 + Math.min(flowMbps, 120) * 0.8;

    for (let i = 0; i < count; i += 1) {
      const point = pointOnRoute(metrics, this.time * speed + (i / count) * metrics.total);
      ctx.fillStyle = '#f0ffff';
      ctx.fillRect(Math.round(point.x) - 2, Math.round(point.y) - 2, 5, 5);
      ctx.fillStyle = color;
      ctx.fillRect(Math.round(point.x) - 1, Math.round(point.y) - 1, 3, 3);
    }
  }

  #drawRouteBadge(ctx, metrics, text) {
    const point = pointOnRoute(metrics, metrics.total * 0.55);
    ctx.font = '10px "Lucida Console", monospace';
    const width = Math.ceil(ctx.measureText(text).width + 16);

    ctx.fillStyle = '#151515';
    ctx.strokeStyle = '#606060';
    ctx.lineWidth = 2;
    ctx.fillRect(Math.round(point.x - width / 2), Math.round(point.y - 30), width, 20);
    ctx.strokeRect(Math.round(point.x - width / 2), Math.round(point.y - 30), width, 20);

    ctx.fillStyle = '#efeee8';
    ctx.textAlign = 'center';
    ctx.fillText(text, Math.round(point.x), Math.round(point.y - 16));
  }

  #drawClient(ctx, x, y, index, demand, large) {
    const width = large ? 96 : 76;
    const height = large ? 110 : 70;

    ctx.fillStyle = '#050505';
    ctx.fillRect(x - width / 2 - 4, y - height / 2 - 4, width + 8, height + 8);

    ctx.fillStyle = '#efeee7';
    ctx.fillRect(x - width / 2, y - height / 2, width, height);
    ctx.fillStyle = '#9c9f9b';
    ctx.fillRect(x - width / 2 + 7, y - height / 2 + 7, width - 14, height - 14);

    ctx.fillStyle = '#171717';
    ctx.fillRect(x - width * 0.28, y - height * 0.27, width * 0.56, height * 0.33);
    ctx.fillStyle = '#293539';
    ctx.fillRect(x - width * 0.20, y - height * 0.20, width * 0.40, height * 0.18);

    ctx.fillStyle = '#e91e47';
    ctx.fillRect(x - width / 2 + 10, y + height / 2 - 14, 8, 5);

    ctx.fillStyle = '#f1f0e8';
    ctx.font = '9px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText(large ? 'CLIENT' : `CLIENT ${index}`, x, y + height / 2 + 17);

    this.#drawNodeValue(ctx, x, y - height / 2 - 17, demand, '#e91e47');
  }

  #drawSwitch(ctx, state) {
    const x = SWITCH.x;
    const y = SWITCH.y;

    if (this.selectedNode === 'switch') this.#drawSelection(ctx, SWITCH, '#10c927');

    ctx.fillStyle = '#050505';
    ctx.fillRect(x - 54, y - 40, 108, 80);

    ctx.fillStyle = '#efeee8';
    ctx.fillRect(x - 49, y - 35, 98, 70);
    ctx.fillStyle = '#767b77';
    ctx.fillRect(x - 43, y - 29, 86, 58);
    ctx.fillStyle = '#171717';
    ctx.fillRect(x - 36, y - 18, 72, 36);

    for (let i = 0; i < 6; i += 1) {
      const px = x - 29 + i * 12;
      ctx.fillStyle = i < state.client.count ? '#d02be3' : '#3b3b3b';
      ctx.fillRect(px, y - 8, 7, 7);
      ctx.fillStyle = '#10d433';
      ctx.fillRect(px + 1, y + 5, 5, 3);
    }

    ctx.fillStyle = '#f1f0e8';
    ctx.font = '10px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText('SWITCH', x, y + 57);
    this.#drawNodeValue(ctx, x, y - 55, state.switch.capacityMbps, '#10c927');
  }

  #drawServer(ctx, x, y, capacity) {
    if (this.selectedNode === 'server') {
      this.#drawSelection(ctx, { x, y, w: 118, h: 118 }, '#10c927');
    }

    ctx.fillStyle = '#050505';
    ctx.fillRect(x - 61, y - 61, 122, 122);
    ctx.fillStyle = '#efeee8';
    ctx.fillRect(x - 56, y - 56, 112, 112);
    ctx.fillStyle = '#929691';
    ctx.fillRect(x - 47, y - 47, 94, 94);
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
    ctx.fillText('SERVER', x, y + 78);
    this.#drawNodeValue(ctx, x, y - 76, capacity, '#10c927');
  }

  #drawQueue(ctx, state) {
    const fill = getQueueFillRatio(state);
    const slots = 10;
    const filled = Math.ceil(fill * slots);
    const x = SWITCH.x + 82;
    const y = SWITCH.y + 47;

    ctx.fillStyle = '#151515';
    ctx.strokeStyle = fill >= 0.9 ? '#e91e47' : fill >= 0.5 ? '#f4ca00' : '#656565';
    ctx.lineWidth = 2;
    ctx.fillRect(x - 6, y - 8, 150, 29);
    ctx.strokeRect(x - 6, y - 8, 150, 29);

    for (let i = 0; i < slots; i += 1) {
      ctx.fillStyle = i < filled
        ? (fill >= 0.9 ? '#e91e47' : fill >= 0.5 ? '#f4ca00' : '#0797ec')
        : '#2c2c2c';
      ctx.fillRect(x + i * 10, y, 7, 7);
    }

    ctx.fillStyle = '#efeee8';
    ctx.font = '9px "Lucida Console", monospace';
    ctx.textAlign = 'left';
    ctx.fillText(`QUEUE ${state.switch.queueMb.toFixed(0)}/${state.switch.bufferMb} Mb`, x, y + 17);
  }

  #drawDroppedPackets(ctx, state) {
    const loss = getPacketLossPercent(state);
    const count = Math.min(8, Math.max(2, Math.ceil(loss / 3)));

    for (let i = 0; i < count; i += 1) {
      const phase = (this.time * 1.8 + i / count) % 1;
      const x = SWITCH.x + 60 + phase * 80;
      const y = -16 - phase * 34 + i * 2;
      ctx.fillStyle = '#ff3155';
      ctx.fillRect(Math.round(x), Math.round(y), 5, 5);
    }
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

  #drawRevenuePulse(ctx, x, y, state) {
    const income = getIncomePerSecond(state);
    if (income <= 0) return;

    const phase = this.time % 2.2;
    const alpha = clamp(1 - phase / 2.2, 0.15, 1);
    const py = y - phase * 8;

    ctx.globalAlpha = alpha;
    ctx.fillStyle = '#ffe000';
    ctx.beginPath();
    ctx.arc(x, py, 9, 0, Math.PI * 2);
    ctx.fill();

    ctx.fillStyle = '#b9ff8b';
    ctx.font = '12px "Lucida Console", monospace';
    ctx.textAlign = 'left';
    ctx.fillText(`+${income.toFixed(1)}`, x + 14, py + 4);
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
}
