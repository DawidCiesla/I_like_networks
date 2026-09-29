import {
  getBranchDemandMbps,
  getIncomePerSecond,
  getPacketLossPercent,
  getPrimaryDemandMbps,
  getQueueFillRatio,
  getThroughputMbps,
} from '../simulation/model.js';

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

const PHASE2 = {
  switch: { x: 0, y: 0 },
  server: { x: 345, y: 0 },
  clients: [
    { x: -355, y: -210 },
    { x: -355, y: -70 },
    { x: -355, y: 70 },
    { x: -355, y: 210 },
  ],
};

const ROUTED = {
  lanA: { x: -300, y: -145 },
  lanB: { x: -300, y: 170 },
  router: { x: 0, y: 10 },
  serverA: { x: 350, y: -145 },
  serverB: { x: 350, y: 170 },
};

const ROUTES = {
  lanAToRouter: routeMetrics([
    { x: ROUTED.lanA.x + 58, y: ROUTED.lanA.y },
    { x: -150, y: ROUTED.lanA.y },
    { x: -90, y: -75 },
    { x: ROUTED.router.x - 62, y: ROUTED.router.y },
  ]),
  lanBToRouter: routeMetrics([
    { x: ROUTED.lanB.x + 58, y: ROUTED.lanB.y },
    { x: -150, y: ROUTED.lanB.y },
    { x: -90, y: 85 },
    { x: ROUTED.router.x - 62, y: ROUTED.router.y },
  ]),
  routerToA: routeMetrics([
    { x: ROUTED.router.x + 62, y: ROUTED.router.y },
    { x: 145, y: ROUTED.router.y },
    { x: 225, y: -70 },
    { x: ROUTED.serverA.x - 64, y: ROUTED.serverA.y },
  ]),
  routerToB: routeMetrics([
    { x: ROUTED.router.x + 62, y: ROUTED.router.y + 8 },
    { x: 145, y: ROUTED.router.y + 8 },
    { x: 225, y: 105 },
    { x: ROUTED.serverB.x - 64, y: ROUTED.serverB.y },
  ]),
};

function phase2BranchRoute(position) {
  return routeMetrics([
    { x: position.x + 45, y: position.y },
    { x: -210, y: position.y },
    { x: -135, y: position.y * 0.35 },
    { x: PHASE2.switch.x - 55, y: 0 },
  ]);
}

const PHASE2_TRUNK = routeMetrics([
  { x: PHASE2.switch.x + 54, y: 0 },
  { x: 175, y: 0 },
  { x: 225, y: -25 },
  { x: PHASE2.server.x - 63, y: -25 },
  { x: PHASE2.server.x - 63, y: 0 },
]);

export class NetworkRenderer {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.ctx.imageSmoothingEnabled = false;
    this.dpr = Math.min(window.devicePixelRatio || 1, 2);
    this.camera = { x: 0, y: 0, zoom: 1 };
    this.pointer = { dragging: false, x: 0, y: 0 };
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
      this.canvas.setPointerCapture(event.pointerId);
    });

    this.canvas.addEventListener('pointermove', (event) => {
      if (!this.pointer.dragging) return;

      this.camera.x += (event.clientX - this.pointer.x) / this.camera.zoom;
      this.camera.y += (event.clientY - this.pointer.y) / this.camera.zoom;
      this.pointer.x = event.clientX;
      this.pointer.y = event.clientY;
    });

    this.canvas.addEventListener('pointerup', () => {
      this.pointer.dragging = false;
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

    if (state.router.built) {
      this.#drawRoutedNetwork(ctx, state);
    } else {
      this.#drawLegacyNetwork(ctx, state);
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
  }

  #drawLegacyNetwork(ctx, state) {
    if (!state.switch.built) {
      const client = { x: -300, y: 120 };
      const server = { x: 300, y: -110 };
      const direct = routeMetrics([
        { x: client.x + 45, y: client.y },
        { x: -100, y: client.y },
        { x: -60, y: 80 },
        { x: -60, y: server.y },
        { x: server.x - 62, y: server.y },
      ]);

      if (state.linkBuilt) {
        this.#drawRoute(ctx, direct, '#0797ec', getThroughputMbps(state));
      } else {
        this.#drawGhostRoute(ctx, direct);
      }

      this.#drawClient(ctx, client.x, client.y, 'CLIENT', state.client.trafficMbps);
      this.#drawServer(ctx, server.x, server.y, 'SERVER', state.server.capacityMbps, '#10c927');
      return;
    }

    for (let index = 0; index < state.client.count; index += 1) {
      const position = PHASE2.clients[index];
      this.#drawRoute(
        ctx,
        phase2BranchRoute(position),
        '#d02be3',
        state.client.trafficMbps,
      );
      this.#drawClient(
        ctx,
        position.x,
        position.y,
        `CLIENT ${index + 1}`,
        state.client.trafficMbps,
      );
    }

    const queueFill = getQueueFillRatio(state);
    const loss = getPacketLossPercent(state);
    const color = loss > 0 ? '#e91e47' : queueFill >= 0.5 ? '#f4ca00' : '#0797ec';

    this.#drawRoute(ctx, PHASE2_TRUNK, color, getThroughputMbps(state));
    this.#drawSwitch(
      ctx,
      PHASE2.switch.x,
      PHASE2.switch.y,
      'SWITCH',
      state.switch.capacityMbps,
      '#10c927',
    );
    this.#drawServer(
      ctx,
      PHASE2.server.x,
      PHASE2.server.y,
      'SERVER',
      state.server.capacityMbps,
      '#10c927',
    );
    this.#drawQueue(
      ctx,
      PHASE2.switch.x + 80,
      PHASE2.switch.y + 45,
      state.switch.queueMb,
      state.switch.bufferMb,
      color,
    );
  }

  #drawRoutedNetwork(ctx, state) {
    const routerLoss = getPacketLossPercent(state);
    const routerQueue = state.router.queueMb;
    const routerColor = routerLoss > 0
      ? '#e91e47'
      : routerQueue > 0
        ? '#f4ca00'
        : '#0797ec';

    this.#drawNetworkBlock(
      ctx,
      ROUTED.lanA.x,
      ROUTED.lanA.y,
      'LAN A',
      '10.0.1.0/24',
      state.client.count,
      '#d02be3',
    );

    this.#drawRoute(
      ctx,
      ROUTES.lanAToRouter,
      '#d02be3',
      Math.min(getPrimaryDemandMbps(state), state.link.capacityMbps),
    );

    if (state.branch.built) {
      this.#drawNetworkBlock(
        ctx,
        ROUTED.lanB.x,
        ROUTED.lanB.y,
        'LAN B',
        '10.0.2.0/24',
        state.branch.clientCount,
        '#0fbcc4',
      );

      this.#drawRoute(
        ctx,
        ROUTES.lanBToRouter,
        '#0fbcc4',
        Math.min(getBranchDemandMbps(state), state.branch.linkCapacityMbps),
      );
    } else {
      this.#drawGhostRoute(ctx, ROUTES.lanBToRouter);
    }

    this.#drawRouter(ctx, state, routerColor);

    this.#drawRoute(
      ctx,
      ROUTES.routerToA,
      '#0797ec',
      state.router.lastThroughputMbps.primary,
    );

    this.#drawServer(
      ctx,
      ROUTED.serverA.x,
      ROUTED.serverA.y,
      'SERVER A',
      state.server.capacityMbps,
      '#0797ec',
    );

    if (state.secondaryServer.built) {
      this.#drawRoute(
        ctx,
        ROUTES.routerToB,
        '#08b91c',
        state.router.lastThroughputMbps.secondary,
      );

      this.#drawServer(
        ctx,
        ROUTED.serverB.x,
        ROUTED.serverB.y,
        'SERVER B',
        state.secondaryServer.capacityMbps,
        '#08b91c',
      );
    } else {
      this.#drawGhostRoute(ctx, ROUTES.routerToB);
      this.#drawGhostServer(ctx, ROUTED.serverB.x, ROUTED.serverB.y, 'SERVER B');
    }

    this.#drawRouteBadge(
      ctx,
      ROUTES.routerToA,
      `${state.router.lastThroughputMbps.primary.toFixed(0)} Mb/s`,
    );

    if (state.secondaryServer.built) {
      this.#drawRouteBadge(
        ctx,
        ROUTES.routerToB,
        `${state.router.lastThroughputMbps.secondary.toFixed(0)} Mb/s`,
      );
    }

    this.#drawQueue(
      ctx,
      ROUTED.router.x - 70,
      ROUTED.router.y + 72,
      state.router.queueMb,
      state.router.bufferMb,
      routerColor,
    );

    this.#drawRevenuePulse(ctx, state);
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
    ctx.setLineDash([5, 7]);
    ctx.strokeStyle = '#3d3d3d';
    ctx.lineWidth = 11;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();
    ctx.strokeStyle = '#686868';
    ctx.lineWidth = 2;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();
    ctx.restore();
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

    const count = Math.min(12, Math.max(2, Math.ceil(flowMbps / 5)));
    const speed = 30 + Math.min(flowMbps, 120) * 0.7;

    for (let i = 0; i < count; i += 1) {
      const point = pointOnRoute(
        metrics,
        this.time * speed + (i / count) * metrics.total,
      );

      ctx.fillStyle = '#f1ffff';
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
    ctx.fillRect(point.x - width / 2, point.y - 28, width, 20);
    ctx.strokeRect(point.x - width / 2, point.y - 28, width, 20);

    ctx.fillStyle = '#efeee8';
    ctx.textAlign = 'center';
    ctx.fillText(text, point.x, point.y - 14);
  }

  #drawNetworkBlock(ctx, x, y, title, cidr, clients, color) {
    ctx.fillStyle = '#080808';
    ctx.fillRect(x - 62, y - 50, 124, 100);

    ctx.fillStyle = '#ecebe4';
    ctx.fillRect(x - 57, y - 45, 114, 90);

    ctx.fillStyle = '#2a2a2a';
    ctx.fillRect(x - 50, y - 38, 100, 76);

    for (let i = 0; i < clients; i += 1) {
      const col = i % 2;
      const row = Math.floor(i / 2);
      const px = x - 31 + col * 38;
      const py = y - 23 + row * 29;

      ctx.fillStyle = '#111';
      ctx.fillRect(px, py, 25, 17);
      ctx.strokeStyle = color;
      ctx.lineWidth = 2;
      ctx.strokeRect(px, py, 25, 17);
      ctx.fillStyle = '#4a4a4a';
      ctx.fillRect(px + 5, py + 5, 15, 6);
    }

    ctx.fillStyle = '#f1f0e8';
    ctx.font = '10px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText(title, x, y + 66);

    ctx.fillStyle = '#9a9a93';
    ctx.font = '8px "Lucida Console", monospace';
    ctx.fillText(cidr, x, y + 80);
  }

  #drawRouter(ctx, state, color) {
    const { x, y } = ROUTED.router;

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

    ctx.strokeStyle = color;
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

    this.#drawNodeValue(ctx, x, y - 72, state.router.capacityMbps, color);
  }

  #drawSwitch(ctx, x, y, title, capacity, color) {
    ctx.fillStyle = '#050505';
    ctx.fillRect(x - 54, y - 40, 108, 80);
    ctx.fillStyle = '#efeee8';
    ctx.fillRect(x - 49, y - 35, 98, 70);
    ctx.fillStyle = '#767b77';
    ctx.fillRect(x - 43, y - 29, 86, 58);
    ctx.fillStyle = '#171717';
    ctx.fillRect(x - 36, y - 18, 72, 36);

    for (let i = 0; i < 6; i += 1) {
      ctx.fillStyle = color;
      ctx.fillRect(x - 29 + i * 12, y - 8, 7, 7);
    }

    ctx.fillStyle = '#efeee8';
    ctx.font = '10px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText(title, x, y + 57);
    this.#drawNodeValue(ctx, x, y - 55, capacity, color);
  }

  #drawClient(ctx, x, y, title, demand) {
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
    ctx.fillText(title, x, y + 54);
    this.#drawNodeValue(ctx, x, y - 52, demand, '#e91e47');
  }

  #drawServer(ctx, x, y, title, capacity, color) {
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
    ctx.fillText(title, x, y + 78);
    this.#drawNodeValue(ctx, x, y - 76, capacity, color);
  }

  #drawGhostServer(ctx, x, y, title) {
    ctx.save();
    ctx.globalAlpha = 0.28;
    ctx.setLineDash([6, 6]);
    ctx.strokeStyle = '#8b8b8b';
    ctx.lineWidth = 3;
    ctx.strokeRect(x - 55, y - 55, 110, 110);
    ctx.fillStyle = '#a0a09a';
    ctx.font = '10px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText(title, x, y + 75);
    ctx.restore();
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

    for (let i = 0; i < slots; i += 1) {
      ctx.fillStyle = i < filled ? color : '#2c2c2c';
      ctx.fillRect(x + 8 + i * 10, y + 8, 7, 7);
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

  #drawRevenuePulse(ctx, state) {
    const income = getIncomePerSecond(state);
    if (income <= 0) return;

    const phase = this.time % 2.2;
    const alpha = clamp(1 - phase / 2.2, 0.15, 1);
    const x = ROUTED.serverA.x + 76;
    const y = ROUTED.serverA.y + 20 - phase * 8;

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
