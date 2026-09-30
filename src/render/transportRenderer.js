import {
  TRANSPORT_MODES,
  getAbandonmentPercent,
  getAverageWaitMinutes,
  getCorridorADemandPpm,
  getCorridorBDemandPpm,
  getDeliveredPassengersPpm,
  getIncomePerSecond,
  getWaitingFillRatio,
} from '../simulation/model.js';

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

const LINE_A_COLOR = '#0797ec';
const LINE_B_COLOR = '#f4ca00';

const WORLD = Object.freeze({
  stopsA: [
    { x: -430, y: -120, w: 44, h: 54 },
    { x: -340, y: -120, w: 44, h: 54 },
    { x: -250, y: -120, w: 44, h: 54 },
    { x: -160, y: -120, w: 44, h: 54 },
  ],
  terminalA: { x: -65, y: -120, w: 92, h: 74 },
  interchange: { x: 85, y: -120, w: 116, h: 112 },
  stationA: { x: 365, y: -120, w: 126, h: 120 },

  stopsB: [
    { x: -350, y: 180, w: 44, h: 54 },
    { x: -260, y: 180, w: 44, h: 54 },
    { x: -170, y: 180, w: 44, h: 54 },
    { x: -80, y: 180, w: 44, h: 54 },
  ],
  stationB: { x: 365, y: 180, w: 126, h: 120 },
});

function routeMetrics(points) {
  const segments = [];
  let total = 0;

  for (let index = 0; index < points.length - 1; index += 1) {
    const a = points[index];
    const b = points[index + 1];
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length = Math.hypot(dx, dy);

    segments.push({ a, b, dx, dy, length, start: total });
    total += length;
  }

  return { points, segments, total };
}

function pointOnRoute(metrics, distance) {
  if (metrics.total <= 0) {
    return { x: 0, y: 0, tx: 1, ty: 0 };
  }

  const wrapped = ((distance % metrics.total) + metrics.total) % metrics.total;

  const segment = metrics.segments.find(
    (item) => wrapped <= item.start + item.length,
  ) ?? metrics.segments.at(-1);

  const local = clamp(
    (wrapped - segment.start) / Math.max(1, segment.length),
    0,
    1,
  );

  return {
    x: segment.a.x + segment.dx * local,
    y: segment.a.y + segment.dy * local,
    tx: segment.dx / Math.max(1, segment.length),
    ty: segment.dy / Math.max(1, segment.length),
  };
}

const LINE_A_ROUTE = routeMetrics([
  { x: WORLD.stopsA[0].x, y: WORLD.stopsA[0].y },
  { x: WORLD.terminalA.x, y: WORLD.terminalA.y },
  { x: WORLD.interchange.x, y: WORLD.interchange.y },
  { x: WORLD.stationA.x - 64, y: WORLD.stationA.y },
]);

const LINE_B_FEEDER_ROUTE = routeMetrics([
  { x: WORLD.stopsB[0].x, y: WORLD.stopsB[0].y },
  { x: WORLD.stopsB[3].x, y: WORLD.stopsB[3].y },
  { x: 15, y: WORLD.stopsB[3].y },
  { x: WORLD.interchange.x, y: WORLD.interchange.y + 58 },
]);

const LINE_B_DESTINATION_ROUTE = routeMetrics([
  { x: WORLD.interchange.x + 58, y: WORLD.interchange.y + 8 },
  { x: 200, y: -20 },
  { x: 250, y: 70 },
  { x: WORLD.stationB.x - 64, y: WORLD.stationB.y },
]);

const LINE_B_FULL_ROUTE = routeMetrics([
  { x: WORLD.stopsB[0].x, y: WORLD.stopsB[0].y },
  { x: WORLD.stopsB[3].x, y: WORLD.stopsB[3].y },
  { x: 15, y: WORLD.stopsB[3].y },
  { x: WORLD.interchange.x, y: WORLD.interchange.y + 58 },
  { x: WORLD.interchange.x + 58, y: WORLD.interchange.y + 8 },
  { x: 200, y: -20 },
  { x: 250, y: 70 },
  { x: WORLD.stationB.x - 64, y: WORLD.stationB.y },
]);

export class TransportRenderer {
  constructor(canvas, { onSelectionChanged } = {}) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.ctx.imageSmoothingEnabled = false;

    this.dpr = Math.min(window.devicePixelRatio || 1, 2);
    this.camera = { x: 0, y: 0, zoom: 1 };
    this.pointer = {
      dragging: false,
      x: 0,
      y: 0,
      startX: 0,
      startY: 0,
    };

    this.time = 0;
    this.selected = null;
    this.hitTargets = [];
    this.onSelectionChanged = onSelectionChanged;

    this.#bindInput();
    this.resize();
  }

  setSelection(selection) {
    this.selected = selection;
  }

  resize() {
    const rect = this.canvas.getBoundingClientRect();

    this.canvas.width = Math.max(
      1,
      Math.floor(rect.width * this.dpr),
    );

    this.canvas.height = Math.max(
      1,
      Math.floor(rect.height * this.dpr),
    );

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

      this.camera.x +=
        (event.clientX - this.pointer.x)
        / this.camera.zoom;

      this.camera.y +=
        (event.clientY - this.pointer.y)
        / this.camera.zoom;

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
        this.camera.zoom
          * (event.deltaY > 0 ? 0.9 : 1.1),
        0.55,
        2.2,
      );
    }, { passive: false });

    window.addEventListener(
      'resize',
      () => this.resize(),
    );
  }

  #screenToWorld(clientX, clientY) {
    const rect = this.canvas.getBoundingClientRect();

    return {
      x:
        (clientX - rect.left - rect.width / 2)
          / this.camera.zoom
        - this.camera.x,
      y:
        (clientY - rect.top - rect.height / 2)
          / this.camera.zoom
        - this.camera.y,
    };
  }

  #selectAt(clientX, clientY) {
    const point = this.#screenToWorld(
      clientX,
      clientY,
    );

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
    this.time += deltaSeconds;
    this.hitTargets = [];

    const ctx = this.ctx;
    const width = this.canvas.width / this.dpr;
    const height = this.canvas.height / this.dpr;

    ctx.setTransform(
      this.dpr,
      0,
      0,
      this.dpr,
      0,
      0,
    );

    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, width, height);

    this.#drawBackground(ctx, width, height);

    ctx.save();
    ctx.translate(width / 2, height / 2);
    ctx.scale(this.camera.zoom, this.camera.zoom);
    ctx.translate(this.camera.x, this.camera.y);

    this.#drawTransportMap(ctx, state);

    ctx.restore();
  }

  #drawBackground(ctx, width, height) {
    ctx.fillStyle = '#1a1a1a';
    ctx.fillRect(0, 0, width, height);

    const spacing = 22;

    const offsetX =
      ((this.camera.x * this.camera.zoom) % spacing + spacing)
      % spacing;

    const offsetY =
      ((this.camera.y * this.camera.zoom) % spacing + spacing)
      % spacing;

    ctx.fillStyle = '#242424';

    for (
      let x = offsetX;
      x < width;
      x += spacing
    ) {
      for (
        let y = offsetY;
        y < height;
        y += spacing
      ) {
        const px = Math.round(x);
        const py = Math.round(y);

        ctx.fillRect(px - 2, py, 5, 1);
        ctx.fillRect(px, py - 2, 1, 5);
      }
    }
  }

  #drawTransportMap(ctx, state) {
    if (state.corridorA.lineBuilt) {
      this.#drawTransitLine(
        ctx,
        LINE_A_ROUTE,
        LINE_A_COLOR,
        1,
      );

      this.#drawVehicles(
        ctx,
        LINE_A_ROUTE,
        state.corridorA.fleetCount,
        LINE_A_COLOR,
        state.corridorA.mode,
      );
    } else {
      this.#drawGhostLine(
        ctx,
        LINE_A_ROUTE,
      );
    }

    for (
      let index = 0;
      index < state.corridorA.stopCount;
      index += 1
    ) {
      const rect = WORLD.stopsA[index];

      this.#drawStop(
        ctx,
        rect,
        `A${index + 1}`,
        LINE_A_COLOR,
        this.selected === 'corridorA',
      );

      this.hitTargets.push({
        id: 'corridorA',
        rect,
      });
    }

    if (state.terminalA.built) {
      this.#drawTerminal(
        ctx,
        WORLD.terminalA,
        'NORTHSIDE',
        LINE_A_COLOR,
        this.selected === 'terminalA',
      );

      this.hitTargets.push({
        id: 'terminalA',
        rect: WORLD.terminalA,
      });
    } else if (state.corridorA.lineBuilt) {
      this.#drawFutureMarker(
        ctx,
        WORLD.terminalA.x,
        WORLD.terminalA.y,
        LINE_A_COLOR,
      );
    }

    if (state.interchange.built) {
      this.#drawInterchange(
        ctx,
        WORLD.interchange,
        state,
        this.selected === 'interchange',
      );

      this.hitTargets.push({
        id: 'interchange',
        rect: WORLD.interchange,
      });
    } else if (state.corridorA.lineBuilt) {
      this.#drawFutureMarker(
        ctx,
        WORLD.interchange.x,
        WORLD.interchange.y,
        LINE_A_COLOR,
      );
    }

    this.#drawStation(
      ctx,
      WORLD.stationA,
      'CENTRAL',
      LINE_A_COLOR,
      state.stationA.capacityPpm,
      this.selected === 'stationA',
    );

    this.hitTargets.push({
      id: 'stationA',
      rect: WORLD.stationA,
    });

    if (state.corridorB.built) {
      this.#drawTransitLine(
        ctx,
        LINE_B_FEEDER_ROUTE,
        LINE_B_COLOR,
        2,
      );

      if (!state.stationB.built) {
        this.#drawVehicles(
          ctx,
          LINE_B_FEEDER_ROUTE,
          state.corridorB.fleetCount,
          LINE_B_COLOR,
          state.corridorB.mode,
        );
      }

      for (
        let index = 0;
        index < state.corridorB.stopCount;
        index += 1
      ) {
        const rect = WORLD.stopsB[index];

        this.#drawStop(
          ctx,
          rect,
          `B${index + 1}`,
          LINE_B_COLOR,
          this.selected === 'corridorB',
        );

        this.hitTargets.push({
          id: 'corridorB',
          rect,
        });
      }
    }

    if (state.stationB.built) {
      this.#drawTransitLine(
        ctx,
        LINE_B_DESTINATION_ROUTE,
        LINE_B_COLOR,
        2,
      );

      this.#drawVehicles(
        ctx,
        LINE_B_FULL_ROUTE,
        state.corridorB.fleetCount,
        LINE_B_COLOR,
        state.corridorB.mode,
      );

      this.#drawStation(
        ctx,
        WORLD.stationB,
        'HARBOR',
        LINE_B_COLOR,
        state.stationB.capacityPpm,
        this.selected === 'stationB',
      );

      this.hitTargets.push({
        id: 'stationB',
        rect: WORLD.stationB,
      });
    }

    if (
      state.terminalA.built
      && state.terminalA.queuePassengers > 0
    ) {
      this.#drawPassengerQueue(
        ctx,
        WORLD.terminalA.x - 70,
        WORLD.terminalA.y + 58,
        state.terminalA.queuePassengers,
        state.terminalA.waitingCapacityPassengers,
      );
    }

    if (
      state.corridorB.built
      && state.corridorB.queuePassengers > 0
    ) {
      this.#drawPassengerQueue(
        ctx,
        WORLD.stopsB[0].x - 48,
        WORLD.stopsB[0].y + 54,
        state.corridorB.queuePassengers,
        state.corridorB.waitingCapacityPassengers,
      );
    }

    if (state.interchange.built) {
      const totalWaiting =
        state.interchange.queuePassengers
        + state.interchange.destinationQueuesPassengers.primary
        + state.interchange.destinationQueuesPassengers.secondary;

      if (totalWaiting > 0) {
        this.#drawPassengerQueue(
          ctx,
          WORLD.interchange.x - 72,
          WORLD.interchange.y + 74,
          totalWaiting,
          state.interchange.waitingCapacityPassengers * 2,
        );
      }
    }

    if (state.corridorA.lineBuilt) {
      this.#drawRevenuePulse(
        ctx,
        state,
      );
    }

    this.#drawSystemReadout(ctx, state);
  }

  #drawTransitLine(
    ctx,
    metrics,
    color,
    lineNumber,
  ) {
    ctx.save();
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';

    ctx.strokeStyle = '#050505';
    ctx.lineWidth = 15;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    ctx.strokeStyle = color;
    ctx.lineWidth = 10;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    ctx.strokeStyle = '#171717';
    ctx.lineWidth = 4;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    this.#drawLineMarkers(
      ctx,
      metrics,
      color,
      lineNumber,
    );

    ctx.restore();
  }

  #drawGhostLine(ctx, metrics) {
    ctx.save();
    ctx.setLineDash([6, 8]);

    ctx.strokeStyle = '#393939';
    ctx.lineWidth = 10;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    ctx.strokeStyle = '#656565';
    ctx.lineWidth = 2;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    ctx.restore();
  }

  #traceRoute(ctx, metrics) {
    ctx.beginPath();
    ctx.moveTo(
      metrics.points[0].x,
      metrics.points[0].y,
    );

    for (
      let index = 1;
      index < metrics.points.length;
      index += 1
    ) {
      ctx.lineTo(
        metrics.points[index].x,
        metrics.points[index].y,
      );
    }
  }

  #drawLineMarkers(
    ctx,
    metrics,
    color,
    lineNumber,
  ) {
    for (
      let distance = 8;
      distance < metrics.total;
      distance += 34
    ) {
      const point = pointOnRoute(
        metrics,
        distance,
      );

      ctx.fillStyle = '#121212';
      ctx.strokeStyle = color;
      ctx.lineWidth = 2;

      ctx.beginPath();
      ctx.arc(
        point.x,
        point.y,
        6,
        0,
        Math.PI * 2,
      );
      ctx.fill();
      ctx.stroke();

      ctx.fillStyle = '#f0efe8';
      ctx.font = '7px "Lucida Console", monospace';
      ctx.textAlign = 'center';
      ctx.fillText(
        String(lineNumber),
        point.x,
        point.y + 2.5,
      );
    }
  }

  #drawVehicles(
    ctx,
    metrics,
    fleetCount,
    color,
    mode,
  ) {
    if (fleetCount <= 0) return;

    const count = clamp(
      fleetCount,
      1,
      8,
    );

    const modeConfig =
      TRANSPORT_MODES[mode]
      ?? TRANSPORT_MODES.bus;

    const speed =
      28 + modeConfig.speedKph * 0.35;

    for (
      let index = 0;
      index < count;
      index += 1
    ) {
      const distance =
        this.time * speed
        + (index / count) * metrics.total;

      const point = pointOnRoute(
        metrics,
        distance,
      );

      this.#drawBus(
        ctx,
        point,
        color,
      );
    }
  }

  #drawBus(ctx, point, color) {
    const angle = Math.atan2(
      point.ty,
      point.tx,
    );

    ctx.save();

    ctx.translate(
      Math.round(point.x),
      Math.round(point.y),
    );

    ctx.rotate(angle);

    ctx.fillStyle = '#050505';
    ctx.fillRect(-9, -5, 18, 10);

    ctx.fillStyle = color;
    ctx.fillRect(-8, -4, 16, 8);

    ctx.fillStyle = '#d9f6ff';
    ctx.fillRect(-5, -3, 4, 3);
    ctx.fillRect(1, -3, 4, 3);

    ctx.fillStyle = '#111';
    ctx.fillRect(-6, 4, 4, 2);
    ctx.fillRect(2, 4, 4, 2);

    ctx.restore();
  }

  #drawStop(
    ctx,
    rect,
    label,
    color,
    selected,
  ) {
    const { x, y } = rect;

    if (selected) {
      this.#drawSelection(
        ctx,
        rect,
        color,
      );
    }

    ctx.fillStyle = '#0b0b0b';
    ctx.fillRect(
      x - 18,
      y - 23,
      36,
      46,
    );

    ctx.fillStyle = '#efeee8';
    ctx.fillRect(
      x - 14,
      y - 19,
      28,
      38,
    );

    ctx.fillStyle = color;
    ctx.fillRect(
      x - 3,
      y - 15,
      6,
      23,
    );

    ctx.fillStyle = '#1a1a1a';
    ctx.fillRect(
      x - 9,
      y + 10,
      18,
      5,
    );

    ctx.fillStyle = '#efeee8';
    ctx.font = '8px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText(
      label,
      x,
      y + 37,
    );
  }

  #drawTerminal(
    ctx,
    rect,
    label,
    color,
    selected,
  ) {
    const { x, y } = rect;

    if (selected) {
      this.#drawSelection(
        ctx,
        rect,
        color,
      );
    }

    ctx.fillStyle = '#050505';
    ctx.fillRect(
      x - 46,
      y - 37,
      92,
      74,
    );

    ctx.fillStyle = '#efeee8';
    ctx.fillRect(
      x - 41,
      y - 32,
      82,
      64,
    );

    ctx.fillStyle = '#7d817d';
    ctx.fillRect(
      x - 34,
      y - 25,
      68,
      50,
    );

    ctx.fillStyle = '#151515';
    ctx.fillRect(
      x - 27,
      y - 14,
      54,
      24,
    );

    for (
      let index = 0;
      index < 4;
      index += 1
    ) {
      ctx.fillStyle = color;
      ctx.fillRect(
        x - 22 + index * 14,
        y - 8,
        8,
        8,
      );
    }

    ctx.fillStyle = '#efeee8';
    ctx.font = '9px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText(
      label,
      x,
      y + 52,
    );
  }

  #drawInterchange(
    ctx,
    rect,
    state,
    selected,
  ) {
    const { x, y } = rect;

    if (selected) {
      this.#drawSelection(
        ctx,
        rect,
        '#f3f3ec',
      );
    }

    ctx.fillStyle = '#050505';
    ctx.fillRect(
      x - 58,
      y - 56,
      116,
      112,
    );

    ctx.fillStyle = '#efeee8';
    ctx.fillRect(
      x - 52,
      y - 50,
      104,
      100,
    );

    ctx.fillStyle = '#777b77';
    ctx.fillRect(
      x - 44,
      y - 42,
      88,
      84,
    );

    ctx.fillStyle = '#151515';
    ctx.fillRect(
      x - 35,
      y - 27,
      70,
      54,
    );

    ctx.strokeStyle = LINE_A_COLOR;
    ctx.lineWidth = 4;
    ctx.beginPath();
    ctx.moveTo(x - 25, y - 10);
    ctx.lineTo(x + 25, y - 10);
    ctx.stroke();

    ctx.strokeStyle = LINE_B_COLOR;
    ctx.beginPath();
    ctx.moveTo(x - 25, y + 10);
    ctx.lineTo(x + 25, y + 10);
    ctx.stroke();

    ctx.fillStyle = '#efeee8';
    ctx.font = '9px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText(
      'INTERCHANGE',
      x,
      y + 73,
    );

    this.#drawCapacityBadge(
      ctx,
      x,
      y - 69,
      state.interchange.transferCapacityPpm,
      '#efeee8',
    );
  }

  #drawStation(
    ctx,
    rect,
    label,
    color,
    capacity,
    selected,
  ) {
    const { x, y } = rect;

    if (selected) {
      this.#drawSelection(
        ctx,
        rect,
        color,
      );
    }

    ctx.fillStyle = '#050505';
    ctx.fillRect(
      x - 63,
      y - 60,
      126,
      120,
    );

    ctx.fillStyle = '#efeee8';
    ctx.fillRect(
      x - 57,
      y - 54,
      114,
      108,
    );

    ctx.fillStyle = '#999b96';
    ctx.fillRect(
      x - 48,
      y - 45,
      96,
      90,
    );

    ctx.fillStyle = '#151515';
    ctx.fillRect(
      x - 36,
      y - 31,
      72,
      55,
    );

    ctx.strokeStyle = color;
    ctx.lineWidth = 3;

    for (
      let row = -19;
      row <= 13;
      row += 16
    ) {
      ctx.beginPath();
      ctx.moveTo(
        x - 26,
        y + row,
      );
      ctx.lineTo(
        x + 26,
        y + row,
      );
      ctx.stroke();
    }

    ctx.fillStyle = '#efeee8';
    ctx.font = '10px "Lucida Console", monospace';
    ctx.textAlign = 'center';
    ctx.fillText(
      label,
      x,
      y + 78,
    );

    this.#drawCapacityBadge(
      ctx,
      x,
      y - 75,
      capacity,
      color,
    );
  }

  #drawCapacityBadge(
    ctx,
    x,
    y,
    value,
    color,
  ) {
    const text = String(
      Math.round(value),
    );

    const width =
      text.length >= 3
        ? 35
        : 29;

    ctx.fillStyle = '#202020';
    ctx.strokeStyle = color;
    ctx.lineWidth = 3;

    ctx.fillRect(
      x - width / 2,
      y - 10,
      width,
      20,
    );

    ctx.strokeRect(
      x - width / 2,
      y - 10,
      width,
      20,
    );

    ctx.fillStyle = '#efeee8';
    ctx.font = '10px "Lucida Console", monospace';
    ctx.textAlign = 'center';

    ctx.fillText(
      text,
      x,
      y + 4,
    );
  }

  #drawFutureMarker(
    ctx,
    x,
    y,
    color,
  ) {
    ctx.fillStyle = '#151515';
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;

    ctx.fillRect(
      x - 8,
      y - 8,
      16,
      16,
    );

    ctx.strokeRect(
      x - 8,
      y - 8,
      16,
      16,
    );
  }

  #drawPassengerQueue(
    ctx,
    x,
    y,
    waiting,
    capacity,
  ) {
    const ratio =
      capacity > 0
        ? clamp(waiting / capacity, 0, 1)
        : 0;

    const color =
      ratio >= 0.9
        ? '#e91e47'
        : ratio >= 0.5
          ? '#f4ca00'
          : '#efeee8';

    ctx.fillStyle = '#151515';
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;

    ctx.fillRect(
      x,
      y,
      132,
      33,
    );

    ctx.strokeRect(
      x,
      y,
      132,
      33,
    );

    const people = clamp(
      Math.ceil(ratio * 10),
      0,
      10,
    );

    for (
      let index = 0;
      index < 10;
      index += 1
    ) {
      const px =
        x + 10 + index * 10;

      ctx.fillStyle =
        index < people
          ? color
          : '#333';

      ctx.fillRect(
        px,
        y + 8,
        4,
        4,
      );

      ctx.fillRect(
        px - 1,
        y + 13,
        6,
        7,
      );
    }

    ctx.fillStyle = '#efeee8';
    ctx.font = '8px "Lucida Console", monospace';
    ctx.textAlign = 'left';

    ctx.fillText(
      `WAITING ${waiting.toFixed(0)}`,
      x + 8,
      y + 29,
    );
  }

  #drawRevenuePulse(
    ctx,
    state,
  ) {
    const income = getIncomePerSecond(state);

    if (income <= 0) return;

    const phase =
      this.time % 2.2;

    const alpha = clamp(
      1 - phase / 2.2,
      0.15,
      1,
    );

    const x =
      WORLD.stationA.x + 76;

    const y =
      WORLD.stationA.y
      + 15
      - phase * 8;

    ctx.globalAlpha = alpha;

    ctx.fillStyle = '#ffe000';
    ctx.beginPath();
    ctx.arc(
      x,
      y,
      8,
      0,
      Math.PI * 2,
    );
    ctx.fill();

    ctx.fillStyle = '#b9ff8b';
    ctx.font = '11px "Lucida Console", monospace';
    ctx.textAlign = 'left';

    ctx.fillText(
      `+${income.toFixed(1)}`,
      x + 13,
      y + 4,
    );

    ctx.globalAlpha = 1;
  }

  #drawSystemReadout(
    ctx,
    state,
  ) {
    if (!state.corridorA.lineBuilt) return;

    const delivered =
      getDeliveredPassengersPpm(state);

    const wait =
      getAverageWaitMinutes(state);

    const abandonment =
      getAbandonmentPercent(state);

    const x = -35;
    const y = -245;

    ctx.fillStyle = '#151515';
    ctx.strokeStyle = '#4e4e4e';
    ctx.lineWidth = 2;

    ctx.fillRect(
      x - 95,
      y - 18,
      190,
      52,
    );

    ctx.strokeRect(
      x - 95,
      y - 18,
      190,
      52,
    );

    ctx.fillStyle = '#efeee8';
    ctx.font = '9px "Lucida Console", monospace';
    ctx.textAlign = 'left';

    ctx.fillText(
      `DELIVERED ${delivered.toFixed(0)} pax/min`,
      x - 85,
      y,
    );

    ctx.fillStyle =
      wait > 5
        ? '#f4ca00'
        : '#aaa9a2';

    ctx.fillText(
      `AVG WAIT ${wait.toFixed(1)} min`,
      x - 85,
      y + 14,
    );

    ctx.fillStyle =
      abandonment > 0
        ? '#e91e47'
        : '#aaa9a2';

    ctx.fillText(
      `LEFT QUEUE ${abandonment.toFixed(1)}%`,
      x - 85,
      y + 28,
    );
  }

  #drawSelection(
    ctx,
    rect,
    color,
  ) {
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
}
