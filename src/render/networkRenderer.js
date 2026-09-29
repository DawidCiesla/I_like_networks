import {
  getBranchDemandMbps,
  getIncomePerSecond,
  getPacketLossPercent,
  getPrimaryDemandMbps,
  getQueueFillRatio,
  getThroughputMbps,
} from '../simulation/model.js';

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

const WORLD = Object.freeze({
  switch: { x: -145, y: 0, w: 108, h: 80 },
  router: { x: 70, y: 0, w: 116, h: 116 },
  serverA: { x: 365, y: -125, w: 122, h: 122 },
  lanB: { x: -150, y: 235, w: 126, h: 102 },
  serverB: { x: 365, y: 205, w: 122, h: 122 },
  clients: [
    { x: -425, y: -195, w: 86, h: 76 },
    { x: -425, y: -65, w: 86, h: 76 },
    { x: -425, y: 65, w: 86, h: 76 },
    { x: -425, y: 195, w: 86, h: 76 },
  ],
});

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
  const segment = metrics.segments.find(
    (item) => wrapped <= item.start + item.length,
  ) ?? metrics.segments.at(-1);

  const local = clamp((wrapped - segment.start) / segment.length, 0, 1);

  return {
    x: segment.a.x + segment.dx * local,
    y: segment.a.y + segment.dy * local,
    tx: segment.dx / Math.max(1, segment.length),
    ty: segment.dy / Math.max(1, segment.length),
  };
}

function clientRoute(index) {
  const client = WORLD.clients[index];

  return routeMetrics([
    { x: client.x + client.w / 2, y: client.y },
    { x: -285, y: client.y },
    { x: -220, y: client.y * 0.42 },
    { x: WORLD.switch.x - WORLD.switch.w / 2, y: 0 },
  ]);
}

const SWITCH_TO_ROUTER = routeMetrics([
  { x: WORLD.switch.x + WORLD.switch.w / 2, y: 0 },
  { x: WORLD.router.x - WORLD.router.w / 2, y: 0 },
]);

const ROUTER_TO_SERVER_A = routeMetrics([
  { x: WORLD.router.x + WORLD.router.w / 2, y: 0 },
  { x: 200, y: 0 },
  { x: 260, y: -60 },
  { x: WORLD.serverA.x - WORLD.serverA.w / 2, y: WORLD.serverA.y },
]);

const LAN_B_TO_ROUTER = routeMetrics([
  { x: WORLD.lanB.x + WORLD.lanB.w / 2, y: WORLD.lanB.y },
  { x: -20, y: WORLD.lanB.y },
  { x: 15, y: 125 },
  { x: WORLD.router.x, y: WORLD.router.y + WORLD.router.h / 2 },
]);

const ROUTER_TO_SERVER_B = routeMetrics([
  { x: WORLD.router.x + WORLD.router.w / 2, y: 12 },
  { x: 195, y: 12 },
  { x: 255, y: 105 },
  { x: WORLD.serverB.x - WORLD.serverB.w / 2, y: WORLD.serverB.y },
]);

export class NetworkRenderer {
  constructor(canvas, { onSelectionChanged } = {}) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.ctx.imageSmoothingEnabled = false;
    this.dpr = Math.min(window.devicePixelRatio || 1, 2);
    this.camera = { x: 0, y: 0, zoom: 1 };
    this.pointer = { dragging: false, x: 0, y: 0, startX: 0, startY: 0 };
    this.time = 0;
    this.selected = null;
    this.hitTargets = [];
    this.onSelectionChanged = onSelectionChanged;
    this.lastState = null;

    this.#bindInput();
    this.resize();
  }

  setSelection(selection) {
    this.selected = selection;
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
      const moved = Math.hypot(
        event.clientX - this.pointer.startX,
        event.clientY - this.pointer.startY,
      );

      this.pointer.dragging = false;

      if (moved < 5) {
        this.#selectAt(event.clientX, event.clientY);
      }
    });

    this.canvas.addEventListener('wheel', (event) => {
      event.preventDefault();
      this.camera.zoom = clamp(
        this.camera.zoom * (event.deltaY > 0 ? 0.9 : 1.1),
        0.55,
        2.2,
      );
    }, { passive: false });

    window.addEventListener('resize', () => this.resize());
  }

  #screenToWorld(clientX, clientY) {
    const rect = this.canvas.getBoundingClientRect();

    return {
      x: (clientX - rect.left - rect.width / 2) / this.camera.zoom - this.camera.x,
      y: (clientY - rect.top - rect.height / 2) / this.camera.zoom - this.camera.y,
    };
  }

  #selectAt(clientX, clientY) {
    const point = this.#screenToWorld(clientX, clientY);

    const target = [...this.hitTargets]
      .reverse()
      .find(({ rect }) => (
        point.x >= rect.x - rect.w / 2
        && point.x <= rect.x + rect.w / 2
        && point.y >= rect.y - rect.h / 2
        && point.y <= rect.y + rect.h / 2
      ));

    this.selected = target?.id ?? null;
    this.onSelectionChanged?.(this.selected);
  }

  render(state, deltaSeconds) {
    this.lastState = state;
    this.time += deltaSeconds;
    this.hitTargets = [];

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

    this.#drawStableNetwork(ctx, state);

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

  #drawStableNetwork(ctx, state) {
    const primaryDemand = getPrimaryDemandMbps(state);
    const primaryFlow = state.router.built
      ? Math.min(primaryDemand, state.link.capacityMbps, state.switch.capacityMbps)
      : getThroughputMbps(state);

    for (let index = 0; index < state.client.count; index += 1) {
      const route = clientRoute(index);
      const flow = index === 0 || state.switch.built ? state.client.trafficMbps : 0;

      if (state.linkBuilt && (index === 0 || state.switch.built)) {
        this.#drawRoute(ctx, route, '#d02be3', flow);
      }

      this.#drawClient(
        ctx,
        WORLD.clients[index],
        index + 1,
        state.client.trafficMbps,
        this.selected === 'lanA',
      );
    }

    if (state.linkBuilt) {
      const queueFill = getQueueFillRatio(state);
      const packetLoss = getPacketLossPercent(state);
      const coreColor = packetLoss > 0
        ? '#e91e47'
        : queueFill >= 0.5 && !state.router.built
          ? '#f4ca00'
          : '#0797ec';

      this.#drawRoute(ctx, SWITCH_TO_ROUTER, coreColor, primaryFlow);

      if (state.router.built) {
        this.#drawRoute(
          ctx,
          ROUTER_TO_SERVER_A,
          '#0797ec',
          state.router.lastThroughputMbps.primary,
        );
      } else {
        this.#drawRoute(ctx, ROUTER_TO_SERVER_A, coreColor, getThroughputMbps(state));
      }
    }

    if (state.switch.built) {
      this.#drawSwitch(ctx, state, this.selected === 'switch');
      this.hitTargets.push({ id: 'switch', rect: WORLD.switch });
    } else {
      this.#drawJunctionMarker(ctx, WORLD.switch.x, WORLD.switch.y, '#d02be3');
    }

    if (state.router.built) {
      this.#drawRouter(ctx, state, this.selected === 'router');
      this.hitTargets.push({ id: 'router', rect: WORLD.router });
    } else if (state.linkBuilt) {
      this.#drawJunctionMarker(ctx, WORLD.router.x, WORLD.router.y, '#0797ec');
    }

    this.#drawServer(
      ctx,
      WORLD.serverA,
      'SERVER A',
      state.server.capacityMbps,
      '#08b91c',
      this.selected === 'serverA',
    );
    this.hitTargets.push({ id: 'serverA', rect: WORLD.serverA });

    if (state.branch.built) {
      this.#drawRoute(
        ctx,
        LAN_B_TO_ROUTER,
        '#0fbcc4',
        Math.min(getBranchDemandMbps(state), state.branch.linkCapacityMbps),
      );

      this.#drawNetworkBlock(
        ctx,
        WORLD.lanB,
        'LAN B',
        '10.0.2.0/24',
        state.branch.clientCount,
        '#0fbcc4',
        this.selected === 'lanB',
      );

      this.hitTargets.push({ id: 'lanB', rect: WORLD.lanB });
    }

    if (state.secondaryServer.built) {
      this.#drawRoute(
        ctx,
        ROUTER_TO_SERVER_B,
        '#08b91c',
        state.router.lastThroughputMbps.secondary,
      );

      this.#drawServer(
        ctx,
        WORLD.serverB,
        'SERVER B',
        state.secondaryServer.capacityMbps,
        '#08b91c',
        this.selected === 'serverB',
      );

      this.hitTargets.push({ id: 'serverB', rect: WORLD.serverB });
    }

    if (state.router.built) {
      const routerQueue = state.router.queueMb
        + state.router.routeQueuesMb.primary
        + state.router.routeQueuesMb.secondary;

      this.#drawQueue(
        ctx,
        WORLD.router.x - 72,
        WORLD.router.y + 76,
        routerQueue,
        state.router.bufferMb * 2,
        routerQueue > state.router.bufferMb ? '#f4ca00' : '#0797ec',
      );
    } else if (state.switch.built && state.switch.queueMb > 0) {
      this.#drawQueue(
        ctx,
        WORLD.switch.x + 68,
        WORLD.switch.y + 48,
        state.switch.queueMb,
        state.switch.bufferMb,
        '#f4ca00',
      );
    }

    for (let index = 0; index < state.client.count; index += 1) {
      this.hitTargets.push({ id: 'lanA', rect: WORLD.clients[index] });
    }

    if (state.linkBuilt) this.#drawRevenuePulse(ctx, state);
  }

  #traceRoute(ctx, metrics) {
    ctx.beginPath();
    ctx.moveTo(metrics.points[0].x, metrics.points[0].y);

    for (let i = 1; i < metrics.points.length; i += 1) {
      ctx.lineTo(metrics.points[i].x, metrics.points[i].y);
    }
  }

  #drawRoute(ctx, metrics, color, flowMbps) {
    ctx.save();
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';

    ctx.strokeStyle = '#050505';
    ctx.lineWidth = 16;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    ctx.strokeStyle = color;
    ctx.lineWidth = 11;
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
    for (let distance = 6; distance < metrics.total; distance += 14) {
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

    const count = Math.min(14, Math.max(2, Math.ceil(flowMbps / 5)));
    const speed = 30 + Math.min(flowMbps, 140) * 0.7;

    for (let index = 0; index < count; index += 1) {
      const point = pointOnRoute(
        metrics,
        this.time * speed + (index / count) * metrics.total,
      );

      ctx.fillStyle = '#f2ffff';
      ctx.fillRect(Math.round(point.x) - 2, Math.round(point.y) - 2, 5, 5);

      ctx.fillStyle = color;
      ctx.fillRect(Math.round(point.x) - 1, Math.round(point.y) - 1, 3, 3);
    }
  }

  #drawClient(ctx, rect, index, demand, selected) {
    const { x, y } = rect;

    if (selected) this.#drawSelection(ctx, rect, '#e91e47');

    ctx.fillStyle = '#050505';
    ctx.fillRect(x - 43, y - 38, 86, 76);

    ctx.fillStyle = '#efeee8';
    ctx.fillRect(x - 39, y - 34, 78, 68);

    ctx.fillStyle = '#969a96';
    ctx.fillRect(x - 32, y - 27, 64, 54);

    ctx.fillStyle = '#171717';
    ctx.fillRect(x - 22, y - 19, 44, 25);

    ctx.fillStyle = '#28363a';
    ctx.fillRect(x - 16, y - 13, 32, 13);

    ctx.fillStyle = '#e91e47';
    ctx.fillRect(x - 27, y + 17, 7, 4);

    ctx.fillStyle = '#efeee8';
    ctx.font = '9px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText(`CLIENT ${index}`, x, y + 54);

    this.#drawNodeValue(ctx, x, y - 51, demand, '#e91e47');
  }

  #drawSwitch(ctx, state, selected) {
    const { x, y } = WORLD.switch;

    if (selected) this.#drawSelection(ctx, WORLD.switch, '#08b91c');

    ctx.fillStyle = '#050505';
    ctx.fillRect(x - 54, y - 40, 108, 80);

    ctx.fillStyle = '#efeee8';
    ctx.fillRect(x - 49, y - 35, 98, 70);

    ctx.fillStyle = '#767b77';
    ctx.fillRect(x - 43, y - 29, 86, 58);

    ctx.fillStyle = '#171717';
    ctx.fillRect(x - 36, y - 18, 72, 36);

    for (let index = 0; index < 6; index += 1) {
      ctx.fillStyle = index < state.client.count ? '#d02be3' : '#414141';
      ctx.fillRect(x - 29 + index * 12, y - 8, 7, 7);

      ctx.fillStyle = '#10d433';
      ctx.fillRect(x - 28 + index * 12, y + 5, 5, 3);
    }

    ctx.fillStyle = '#efeee8';
    ctx.font = '10px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText('SWITCH', x, y + 58);

    this.#drawNodeValue(ctx, x, y - 55, state.switch.capacityMbps, '#08b91c');
  }

  #drawRouter(ctx, state, selected) {
    const { x, y } = WORLD.router;

    if (selected) this.#drawSelection(ctx, WORLD.router, '#0797ec');

    ctx.fillStyle = '#050505';
    ctx.beginPath();
    ctx.moveTo(x, y - 56);
    ctx.lineTo(x + 58, y);
    ctx.lineTo(x, y + 56);
    ctx.lineTo(x - 58, y);
    ctx.closePath();
    ctx.fill();

    ctx.fillStyle = '#efeee8';
    ctx.beginPath();
    ctx.moveTo(x, y - 49);
    ctx.lineTo(x + 50, y);
    ctx.lineTo(x, y + 49);
    ctx.lineTo(x - 50, y);
    ctx.closePath();
    ctx.fill();

    ctx.fillStyle = '#242424';
    ctx.beginPath();
    ctx.moveTo(x, y - 38);
    ctx.lineTo(x + 39, y);
    ctx.lineTo(x, y + 38);
    ctx.lineTo(x - 39, y);
    ctx.closePath();
    ctx.fill();

    ctx.strokeStyle = '#0797ec';
    ctx.lineWidth = 4;
    ctx.beginPath();
    ctx.moveTo(x - 23, y);
    ctx.lineTo(x + 23, y);
    ctx.moveTo(x, y - 23);
    ctx.lineTo(x, y + 23);
    ctx.stroke();

    ctx.fillStyle = '#efeee8';
    ctx.font = '10px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText('ROUTER', x, y + 75);

    this.#drawNodeValue(ctx, x, y - 72, state.router.capacityMbps, '#0797ec');
  }

  #drawServer(ctx, rect, title, capacity, color, selected) {
    const { x, y } = rect;

    if (selected) this.#drawSelection(ctx, rect, color);

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

      ctx.fillStyle = color;
      ctx.fillRect(x + 12, y + row, 5, 5);
    }

    ctx.fillStyle = '#efeee8';
    ctx.font = '10px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText(title, x, y + 79);

    this.#drawNodeValue(ctx, x, y - 76, capacity, color);
  }

  #drawNetworkBlock(ctx, rect, title, cidr, clients, color, selected) {
    const { x, y } = rect;

    if (selected) this.#drawSelection(ctx, rect, color);

    ctx.fillStyle = '#050505';
    ctx.fillRect(x - 63, y - 51, 126, 102);

    ctx.fillStyle = '#efeee8';
    ctx.fillRect(x - 58, y - 46, 116, 92);

    ctx.fillStyle = '#2b2b2b';
    ctx.fillRect(x - 51, y - 39, 102, 78);

    for (let index = 0; index < clients; index += 1) {
      const column = index % 2;
      const row = Math.floor(index / 2);
      const px = x - 32 + column * 39;
      const py = y - 23 + row * 29;

      ctx.fillStyle = '#111';
      ctx.fillRect(px, py, 25, 17);

      ctx.strokeStyle = color;
      ctx.lineWidth = 2;
      ctx.strokeRect(px, py, 25, 17);

      ctx.fillStyle = '#4a4a4a';
      ctx.fillRect(px + 5, py + 5, 15, 6);
    }

    ctx.fillStyle = '#efeee8';
    ctx.font = '10px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText(title, x, y + 68);

    ctx.fillStyle = '#9a9a93';
    ctx.font = '8px "Lucida Console", monospace';
    ctx.fillText(cidr, x, y + 82);
  }

  #drawJunctionMarker(ctx, x, y, color) {
    ctx.fillStyle = '#151515';
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.fillRect(x - 8, y - 8, 16, 16);
    ctx.strokeRect(x - 8, y - 8, 16, 16);
  }

  #drawQueue(ctx, x, y, queueMb, bufferMb, color) {
    const ratio = bufferMb > 0 ? clamp(queueMb / bufferMb, 0, 1) : 0;
    const slots = 10;
    const filled = Math.ceil(ratio * slots);

    ctx.fillStyle = '#151515';
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.fillRect(x, y, 142, 29);
    ctx.strokeRect(x, y, 142, 29);

    for (let index = 0; index < slots; index += 1) {
      ctx.fillStyle = index < filled ? color : '#2c2c2c';
      ctx.fillRect(x + 8 + index * 10, y + 8, 7, 7);
    }

    ctx.fillStyle = '#efeee8';
    ctx.font = '8px "Lucida Console", monospace';
    ctx.textAlign = 'left';
    ctx.fillText(`QUEUE ${queueMb.toFixed(0)} Mb`, x + 8, y + 24);
  }

  #drawNodeValue(ctx, x, y, value, color) {
    const text = String(Math.round(value));
    const width = text.length >= 3 ? 33 : 27;

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

  #drawSelection(ctx, rect, color) {
    ctx.save();
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.setLineDash([5, 4]);
    ctx.strokeRect(
      rect.x - rect.w / 2 - 8,
      rect.y - rect.h / 2 - 8,
      rect.w + 16,
      rect.h + 16,
    );
    ctx.restore();
  }

  #drawRevenuePulse(ctx, state) {
    const income = getIncomePerSecond(state);
    if (income <= 0) return;

    const phase = this.time % 2.2;
    const alpha = clamp(1 - phase / 2.2, 0.15, 1);
    const x = WORLD.serverA.x + 76;
    const y = WORLD.serverA.y + 20 - phase * 8;

    ctx.globalAlpha = alpha;
    ctx.fillStyle = '#ffe000';
    ctx.beginPath();
    ctx.arc(x, y, 8, 0, Math.PI * 2);
    ctx.fill();

    ctx.fillStyle = '#b9ff8b';
    ctx.font = '11px "Lucida Console", monospace';
    ctx.textAlign = 'left';
    ctx.fillText(`+${income.toFixed(1)}`, x + 13, y + 4);
    ctx.globalAlpha = 1;
  }
}
