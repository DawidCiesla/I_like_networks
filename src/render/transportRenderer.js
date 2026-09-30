import {
  ECONOMY,
  STOP_NAMES,
  canBuildDepot,
  canUnlockLine2,
  getLineDemandPpm,
  getNextStopCost,
  getStopWaitingPassengers,
  getVehicleOnboardPassengers,
} from '../simulation/model.js';

import {
  WORLD,
  getBuiltRoute,
  getDepotSpurRoute,
  getFutureSegmentRoute,
  getSegmentRoute,
  getVehiclePoint,
  pointOnRoute,
} from './transportLayout.js';

import {
  drawCity,
} from './cityRenderer.js';

const clamp = (value, min, max) =>
  Math.min(max, Math.max(min, value));

const LINE_1_COLOR = '#0797ec';
const LINE_2_COLOR = '#f4ca00';

export class TransportRenderer {
  constructor(canvas, { onSelectionChanged } = {}) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.ctx.imageSmoothingEnabled = false;

    this.dpr = Math.min(
      window.devicePixelRatio || 1,
      2,
    );

    this.camera = {
      x: 65,
      y: 20,
      zoom: 0.6,
    };

    this.pointer = {
      dragging: false,
      x: 0,
      y: 0,
      startX: 0,
      startY: 0,
    };

    this.selected = null;
    this.hitTargets = [];
    this.onSelectionChanged =
      onSelectionChanged;

    this.seenEventSerial = {
      line1: 0,
      line2: 0,
    };

    this.passengerAnimations = [];
    this.farePopups = [];
    this.cityTime = 0;

    this.#bindInput();
    this.resize();
  }

  setSelection(selection) {
    this.selected = selection;
  }

  resize() {
    const rect =
      this.canvas.getBoundingClientRect();

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
    this.canvas.addEventListener(
      'pointerdown',
      (event) => {
        this.pointer.dragging = true;
        this.pointer.x = event.clientX;
        this.pointer.y = event.clientY;
        this.pointer.startX = event.clientX;
        this.pointer.startY = event.clientY;
        this.canvas.setPointerCapture(
          event.pointerId,
        );
      },
    );

    this.canvas.addEventListener(
      'pointermove',
      (event) => {
        if (!this.pointer.dragging) return;

        this.camera.x +=
          (event.clientX - this.pointer.x)
          / this.camera.zoom;

        this.camera.y +=
          (event.clientY - this.pointer.y)
          / this.camera.zoom;

        this.pointer.x = event.clientX;
        this.pointer.y = event.clientY;
      },
    );

    this.canvas.addEventListener(
      'pointerup',
      (event) => {
        const moved = Math.hypot(
          event.clientX - this.pointer.startX,
          event.clientY - this.pointer.startY,
        );

        this.pointer.dragging = false;

        if (moved < 5) {
          this.#selectAt(
            event.clientX,
            event.clientY,
          );
        }
      },
    );

    this.canvas.addEventListener(
      'wheel',
      (event) => {
        event.preventDefault();

        this.camera.zoom = clamp(
          this.camera.zoom
            * (event.deltaY > 0 ? 0.9 : 1.1),
          0.25,
          2.2,
        );
      },
      { passive: false },
    );

    window.addEventListener(
      'resize',
      () => this.resize(),
    );
  }

  #screenToWorld(clientX, clientY) {
    const rect =
      this.canvas.getBoundingClientRect();

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
    const point =
      this.#screenToWorld(clientX, clientY);

    const target = [...this.hitTargets]
      .reverse()
      .find(({ rect }) => (
        point.x >= rect.x - rect.w / 2
        && point.x <= rect.x + rect.w / 2
        && point.y >= rect.y - rect.h / 2
        && point.y <= rect.y + rect.h / 2
      ));

    this.selected = target?.id ?? null;

    this.onSelectionChanged?.(
      this.selected,
    );
  }

  render(state, deltaSeconds) {
    this.hitTargets = [];
    this.cityTime += deltaSeconds;

    this.#capturePassengerEvents(
      state,
      'line1',
      WORLD.line1Stops,
      LINE_1_COLOR,
    );

    this.#capturePassengerEvents(
      state,
      'line2',
      WORLD.line2Stops,
      LINE_2_COLOR,
    );

    this.#updateTransientAnimations(
      deltaSeconds,
    );

    const ctx = this.ctx;

    const width =
      this.canvas.width / this.dpr;

    const height =
      this.canvas.height / this.dpr;

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

    this.#drawBackground(
      ctx,
      width,
      height,
    );

    ctx.save();

    ctx.translate(
      width / 2,
      height / 2,
    );

    ctx.scale(
      this.camera.zoom,
      this.camera.zoom,
    );

    ctx.translate(
      this.camera.x,
      this.camera.y,
    );

    drawCity(
      ctx,
      state,
      this.cityTime,
    );

    this.#drawBusEra(ctx, state);
    this.#drawPassengerAnimations(ctx);
    this.#drawFarePopups(ctx);

    ctx.restore();
  }

  #drawBackground(ctx, width, height) {
    ctx.fillStyle = '#1a1a1a';
    ctx.fillRect(0, 0, width, height);

    const spacing = 22;

    const offsetX =
      ((this.camera.x * this.camera.zoom)
        % spacing + spacing)
      % spacing;

    const offsetY =
      ((this.camera.y * this.camera.zoom)
        % spacing + spacing)
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

        ctx.fillRect(
          px - 2,
          py,
          5,
          1,
        );

        ctx.fillRect(
          px,
          py - 2,
          1,
          5,
        );
      }
    }
  }

  #drawBusEra(ctx, state) {
    this.#drawLine(
      ctx,
      state,
      'line1',
      WORLD.line1Stops,
      STOP_NAMES.line1,
      LINE_1_COLOR,
      1,
    );

    this.#drawDepot(ctx, state);

    if (state.line2.built) {
      this.#drawLine(
        ctx,
        state,
        'line2',
        WORLD.line2Stops,
        STOP_NAMES.line2,
        LINE_2_COLOR,
        2,
      );

      this.#drawSharedInterchange(ctx);
    } else {
      this.#drawFutureLine2(ctx, state);
    }

  }

  #drawLine(
    ctx,
    state,
    lineKey,
    stopRects,
    stopNames,
    color,
    lineNumber,
  ) {
    const line = state[lineKey];

    const route = getBuiltRoute(
      lineKey,
      line.stopCount,
    );

    if (line.built) {
      this.#drawTransitLine(
        ctx,
        route,
        color,
        lineNumber,
      );
    }

    for (
      let index = 0;
      index < line.stopCount;
      index += 1
    ) {
      if (
        lineKey === 'line2'
        && index === 0
      ) {
        continue;
      }

      const rect = stopRects[index];

      this.#drawStop(
        ctx,
        rect,
        stopNames[index],
        index + 1,
        color,
        this.selected === lineKey,
        lineKey === 'line1' && index === 0,
      );

      this.#drawWaitingPassengers(
        ctx,
        state,
        lineKey,
        index,
        rect,
        color,
      );

      this.hitTargets.push({
        id: lineKey,
        rect,
      });
    }

    if (line.built) {
      for (const vehicle of line.vehicles) {
        this.#drawVehicle(
          ctx,
          lineKey,
          vehicle,
          color,
        );
      }
    }

    const maxStops =
      lineKey === 'line1'
        ? ECONOMY.maxLine1Stops
        : ECONOMY.maxLine2Stops;

    if (line.stopCount < maxStops) {
      const next =
        stopRects[line.stopCount];

      const ghostRoute =
        getFutureSegmentRoute(
          lineKey,
          line.stopCount,
        );

      this.#drawGhostLine(
        ctx,
        ghostRoute,
        color,
      );

      this.#drawFutureStop(
        ctx,
        next,
        stopNames[line.stopCount],
        getNextStopCost(
          state,
          lineKey,
        ),
        color,
        this.selected
          === (lineKey === 'line1'
            ? 'futureStop1'
            : 'futureStop2'),
      );

      this.hitTargets.push({
        id:
          lineKey === 'line1'
            ? 'futureStop1'
            : 'futureStop2',
        rect: {
          ...next,
          w: 86,
          h: 86,
        },
      });
    }
  }

  #drawFutureLine2(ctx, state) {
    if (!canUnlockLine2(state)) return;

    const next = WORLD.line2Stops[1];

    const route = getSegmentRoute(
      'line2',
      0,
      1,
    );

    this.#drawGhostLine(
      ctx,
      route,
      LINE_2_COLOR,
    );

    this.#drawFutureLine(
      ctx,
      next,
      ECONOMY.line2BuildCost,
      this.selected === 'futureLine2',
    );

    this.hitTargets.push({
      id: 'futureLine2',
      rect: {
        ...next,
        w: 104,
        h: 92,
      },
    });
  }

  #drawDepot(ctx, state) {
    if (state.depot.built) {
      const spur =
        getDepotSpurRoute();

      this.#drawServiceSpur(
        ctx,
        spur,
        '#b7b7ae',
      );

      this.#drawDepotBuilding(
        ctx,
        WORLD.depot,
        state,
        this.selected === 'depot',
      );

      this.hitTargets.push({
        id: 'depot',
        rect: WORLD.depot,
      });

      return;
    }

    if (!canBuildDepot(state)) {
      return;
    }

    const spur =
      getDepotSpurRoute();

    this.#drawGhostLine(
      ctx,
      spur,
      '#b7b7ae',
    );

    this.#drawFutureDepot(
      ctx,
      WORLD.depot,
      ECONOMY.depotBuildCost,
      this.selected === 'futureDepot',
    );

    this.hitTargets.push({
      id: 'futureDepot',
      rect: {
        ...WORLD.depot,
        w: 132,
        h: 100,
      },
    });
  }

  #drawSharedInterchange(ctx) {
    const rect = WORLD.line1Stops[2];

    ctx.save();

    ctx.strokeStyle = '#050505';
    ctx.lineWidth = 8;

    ctx.beginPath();
    ctx.arc(
      rect.x,
      rect.y,
      22,
      0,
      Math.PI * 2,
    );
    ctx.stroke();

    ctx.strokeStyle = LINE_1_COLOR;
    ctx.lineWidth = 4;

    ctx.beginPath();
    ctx.arc(
      rect.x,
      rect.y,
      18,
      Math.PI * 0.1,
      Math.PI * 1.1,
    );
    ctx.stroke();

    ctx.strokeStyle = LINE_2_COLOR;

    ctx.beginPath();
    ctx.arc(
      rect.x,
      rect.y,
      18,
      Math.PI * 1.1,
      Math.PI * 2.1,
    );
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

  #drawTransitLine(
    ctx,
    metrics,
    color,
    lineNumber,
  ) {
    if (metrics.points.length < 2) return;

    ctx.save();
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';

    ctx.strokeStyle = '#111';
    ctx.lineWidth = 7;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    ctx.strokeStyle = color;
    ctx.lineWidth = 4;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    for (
      let distance = 105;
      distance < metrics.total;
      distance += 180
    ) {
      const point =
        pointOnRoute(
          metrics,
          distance,
        );

      ctx.fillStyle = '#111';
      ctx.strokeStyle = color;
      ctx.lineWidth = 2;

      ctx.beginPath();
      ctx.arc(
        point.x,
        point.y,
        8,
        0,
        Math.PI * 2,
      );
      ctx.fill();
      ctx.stroke();

      ctx.fillStyle = '#f0efe8';
      ctx.font =
        '7px "Lucida Console", monospace';
      ctx.textAlign = 'center';

      ctx.fillText(
        String(lineNumber),
        point.x,
        point.y + 2.5,
      );
    }

    ctx.restore();
  }

  #drawGhostLine(
    ctx,
    metrics,
    color,
  ) {
    if (metrics.points.length < 2) return;

    ctx.save();
    ctx.setLineDash([8, 10]);
    ctx.lineCap = 'round';

    ctx.strokeStyle = color;
    ctx.globalAlpha = 0.58;
    ctx.lineWidth = 3;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    ctx.restore();
  }

  #drawServiceSpur(
    ctx,
    metrics,
    color,
  ) {
    ctx.save();
    ctx.setLineDash([4, 4]);
    ctx.strokeStyle = color;
    ctx.lineWidth = 3;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();
    ctx.restore();
  }

  #drawVehicle(
    ctx,
    lineKey,
    vehicle,
    color,
  ) {
    const point =
      getVehiclePoint(
        lineKey,
        vehicle,
      );

    const angle =
      Math.atan2(
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
    ctx.fillRect(-14, -6, 28, 12);

    ctx.fillStyle = '#d7d7cf';
    ctx.fillRect(-13, -5, 26, 10);

    ctx.fillStyle = color;
    ctx.fillRect(-13, 2, 26, 3);

    ctx.fillStyle = '#26383f';
    ctx.fillRect(-10, -4, 5, 4);
    ctx.fillRect(-3, -4, 5, 4);
    ctx.fillRect(4, -4, 5, 4);

    ctx.fillStyle = '#111';
    ctx.fillRect(-10, 5, 5, 2);
    ctx.fillRect(5, 5, 5, 2);

    ctx.restore();

    const onboard =
      getVehicleOnboardPassengers(vehicle);

    if (onboard > 0.5) {
      const loadText =
        String(Math.round(onboard));

      ctx.font =
        '7px "Lucida Console", monospace';

      const width =
        Math.max(
          14,
          ctx.measureText(loadText).width + 7,
        );

      ctx.fillStyle = '#111';
      ctx.strokeStyle = color;
      ctx.lineWidth = 1;

      ctx.fillRect(
        point.x - width / 2,
        point.y - 19,
        width,
        11,
      );

      ctx.strokeRect(
        point.x - width / 2,
        point.y - 19,
        width,
        11,
      );

      ctx.fillStyle = '#efeee8';
      ctx.textAlign = 'center';

      ctx.fillText(
        loadText,
        point.x,
        point.y - 11,
      );
    }
  }

  #drawStop(
    ctx,
    rect,
    label,
    number,
    color,
    selected,
    origin,
  ) {
    const { x, y } = rect;

    if (selected) {
      this.#drawSelection(
        ctx,
        rect,
        color,
      );
    }

    const shelterWidth = origin ? 38 : 30;
    const shelterHeight = origin ? 28 : 23;

    ctx.fillStyle = '#101010';
    ctx.fillRect(
      x - shelterWidth / 2 - 3,
      y - shelterHeight / 2 - 3,
      shelterWidth + 6,
      shelterHeight + 6,
    );

    ctx.fillStyle = '#d8d8d0';
    ctx.fillRect(
      x - shelterWidth / 2,
      y - shelterHeight / 2,
      shelterWidth,
      shelterHeight,
    );

    ctx.fillStyle = '#343b3d';
    ctx.fillRect(
      x - shelterWidth / 2 + 4,
      y - shelterHeight / 2 + 4,
      shelterWidth - 8,
      shelterHeight - 8,
    );

    ctx.fillStyle = color;
    ctx.fillRect(
      x - shelterWidth / 2,
      y + shelterHeight / 2 - 4,
      shelterWidth,
      4,
    );

    ctx.fillStyle = '#e9e8e0';
    ctx.fillRect(
      x + shelterWidth / 2 + 7,
      y - 17,
      3,
      28,
    );

    ctx.fillStyle = color;
    ctx.fillRect(
      x + shelterWidth / 2 + 3,
      y - 19,
      11,
      9,
    );

    ctx.fillStyle = '#111';
    ctx.font =
      '7px "Lucida Console", monospace';
    ctx.textAlign = 'center';

    ctx.fillText(
      String(number),
      x + shelterWidth / 2 + 8.5,
      y - 12,
    );

    const stopLabel =
      label.toUpperCase();

    ctx.font =
      '8px "Lucida Console", monospace';

    const labelWidth =
      ctx.measureText(stopLabel).width + 8;

    ctx.fillStyle = '#151515';
    ctx.globalAlpha = 0.9;

    ctx.fillRect(
      x - labelWidth / 2,
      y + 23,
      labelWidth,
      13,
    );

    ctx.globalAlpha = 1;
    ctx.fillStyle = '#f3f2eb';

    ctx.fillText(
      stopLabel,
      x,
      y + 32,
    );
  }

  #drawWaitingPassengers(
    ctx,
    state,
    lineKey,
    stopIndex,
    rect,
    color,
  ) {
    const waiting =
      getStopWaitingPassengers(
        state,
        lineKey,
        stopIndex,
      );

    if (waiting <= 0.05) return;

    const side =
      lineKey === 'line1'
        ? (stopIndex % 2 === 0 ? -1 : 1)
        : (stopIndex % 2 === 0 ? 1 : -1);

    const visible =
      clamp(
        Math.ceil(waiting),
        1,
        5,
      );

    const baseX =
      rect.x + side * 34;

    const baseY =
      rect.y - 14;

    for (
      let index = 0;
      index < visible;
      index += 1
    ) {
      const py =
        baseY + index * 7;

      ctx.fillStyle = '#efeee8';
      ctx.fillRect(
        baseX - 1,
        py,
        3,
        3,
      );

      ctx.fillStyle = color;
      ctx.fillRect(
        baseX - 2,
        py + 4,
        5,
        4,
      );
    }

    const countText =
      String(
        Math.round(waiting),
      );

    ctx.font =
      '7px "Lucida Console", monospace';

    const badgeWidth =
      Math.max(
        14,
        ctx.measureText(countText).width + 7,
      );

    const badgeX =
      rect.x + side * 47
      - badgeWidth / 2;

    const badgeY =
      rect.y - 31;

    ctx.fillStyle = '#111';
    ctx.strokeStyle = color;
    ctx.lineWidth = 1;

    ctx.fillRect(
      badgeX,
      badgeY,
      badgeWidth,
      11,
    );

    ctx.strokeRect(
      badgeX,
      badgeY,
      badgeWidth,
      11,
    );

    ctx.fillStyle = '#efeee8';
    ctx.textAlign = 'center';

    ctx.fillText(
      countText,
      badgeX + badgeWidth / 2,
      badgeY + 8,
    );
  }

  #drawFutureStop(
    ctx,
    rect,
    label,
    cost,
    color,
    selected,
  ) {
    const { x, y } = rect;

    if (selected) {
      this.#drawSelection(
        ctx,
        {
          ...rect,
          w: 72,
          h: 72,
        },
        color,
      );
    }

    ctx.save();
    ctx.globalAlpha = 0.64;
    ctx.setLineDash([5, 5]);
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;

    ctx.strokeRect(
      x - 22,
      y - 25,
      44,
      50,
    );

    ctx.restore();

    ctx.fillStyle = '#777';
    ctx.font =
      '8px "Lucida Console", monospace';
    ctx.textAlign = 'center';

    ctx.fillText(
      label.toUpperCase(),
      x,
      y + 39,
    );

    ctx.fillStyle = '#f4ca00';

    ctx.fillText(
      `$${cost}`,
      x,
      y + 51,
    );
  }

  #drawFutureDepot(
    ctx,
    rect,
    cost,
    selected,
  ) {
    const { x, y } = rect;

    if (selected) {
      this.#drawSelection(
        ctx,
        rect,
        '#efeee8',
      );
    }

    ctx.save();
    ctx.globalAlpha = 0.55;
    ctx.setLineDash([6, 5]);
    ctx.strokeStyle = '#efeee8';
    ctx.lineWidth = 2;

    ctx.strokeRect(
      x - 55,
      y - 38,
      110,
      76,
    );

    ctx.restore();

    ctx.fillStyle = '#b8b8b1';
    ctx.font =
      '9px "Lucida Console", monospace';
    ctx.textAlign = 'center';

    ctx.fillText(
      'BUS DEPOT',
      x,
      y - 3,
    );

    ctx.fillStyle = '#f4ca00';

    ctx.fillText(
      `UNLOCKED · $${cost}`,
      x,
      y + 14,
    );
  }

  #drawDepotBuilding(
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
        '#efeee8',
      );
    }

    ctx.fillStyle = '#050505';
    ctx.fillRect(
      x - 59,
      y - 43,
      118,
      86,
    );

    ctx.fillStyle = '#efeee8';
    ctx.fillRect(
      x - 54,
      y - 38,
      108,
      76,
    );

    ctx.fillStyle = '#555954';
    ctx.fillRect(
      x - 47,
      y - 31,
      94,
      62,
    );

    const used =
      state.line1.fleetCount
      + state.line2.fleetCount;

    const slots = Math.min(
      state.depot.garageSlots,
      8,
    );

    for (
      let index = 0;
      index < slots;
      index += 1
    ) {
      const col = index % 4;
      const row =
        Math.floor(index / 4);

      const px =
        x - 36 + col * 24;

      const py =
        y - 16 + row * 27;

      ctx.fillStyle =
        index < used
          ? '#0797ec'
          : '#232323';

      ctx.fillRect(
        px,
        py,
        15,
        9,
      );

      ctx.strokeStyle = '#111';
      ctx.strokeRect(
        px,
        py,
        15,
        9,
      );
    }

    ctx.fillStyle = '#efeee8';
    ctx.font =
      '9px "Lucida Console", monospace';
    ctx.textAlign = 'center';

    ctx.fillText(
      'BUS DEPOT',
      x,
      y + 57,
    );
  }

  #drawFutureLine(
    ctx,
    rect,
    cost,
    selected,
  ) {
    if (selected) {
      this.#drawSelection(
        ctx,
        {
          ...rect,
          w: 96,
          h: 86,
        },
        LINE_2_COLOR,
      );
    }

    ctx.fillStyle = '#151515';
    ctx.strokeStyle = LINE_2_COLOR;
    ctx.lineWidth = 2;

    ctx.fillRect(
      rect.x - 47,
      rect.y - 27,
      94,
      54,
    );

    ctx.strokeRect(
      rect.x - 47,
      rect.y - 27,
      94,
      54,
    );

    ctx.fillStyle = '#efeee8';
    ctx.font =
      '9px "Lucida Console", monospace';
    ctx.textAlign = 'center';

    ctx.fillText(
      'NEW BUS LINE',
      rect.x,
      rect.y - 5,
    );

    ctx.fillStyle = '#f4ca00';

    ctx.fillText(
      `LINE 2 · $${cost}`,
      rect.x,
      rect.y + 12,
    );
  }

  #capturePassengerEvents(
    state,
    lineKey,
    stopRects,
    color,
  ) {
    const line = state[lineKey];

    if (!Array.isArray(line?.passengerEvents)) {
      return;
    }

    const unseen =
      line.passengerEvents.filter(
        (event) =>
          event.serial
          > this.seenEventSerial[lineKey],
      );

    for (const event of unseen) {
      const stop =
        stopRects[event.stopIndex];

      if (!stop) continue;

      const visibleCount =
        clamp(
          Math.ceil(event.count),
          1,
          6,
        );

      for (
        let index = 0;
        index < visibleCount;
        index += 1
      ) {
        const spread =
          (index - (visibleCount - 1) / 2)
          * 6;

        const fromX =
          event.type === 'board'
            ? stop.x + spread
            : stop.x;

        const fromY =
          event.type === 'board'
            ? stop.y + 40
            : stop.y;

        const toX =
          event.type === 'board'
            ? stop.x
            : stop.x + spread;

        const toY =
          event.type === 'board'
            ? stop.y
            : stop.y + 40;

        this.passengerAnimations.push({
          type: event.type,
          color,
          fromX,
          fromY,
          toX,
          toY,
          age: 0,
          duration: 0.75,
        });
      }

      if (
        event.type === 'alight'
        && event.fare > 0
      ) {
        this.farePopups.push({
          x: stop.x + 28,
          y: stop.y - 20,
          value: event.fare,
          age: 0,
          duration: 1.5,
        });
      }

      this.seenEventSerial[lineKey] =
        Math.max(
          this.seenEventSerial[lineKey],
          event.serial,
        );
    }
  }

  #updateTransientAnimations(
    deltaSeconds,
  ) {
    for (const animation of this.passengerAnimations) {
      animation.age += deltaSeconds;
    }

    this.passengerAnimations =
      this.passengerAnimations.filter(
        (animation) =>
          animation.age
          < animation.duration,
      );

    for (const popup of this.farePopups) {
      popup.age += deltaSeconds;
    }

    this.farePopups =
      this.farePopups.filter(
        (popup) =>
          popup.age
          < popup.duration,
      );
  }

  #drawPassengerAnimations(ctx) {
    for (const animation of this.passengerAnimations) {
      const t = clamp(
        animation.age / animation.duration,
        0,
        1,
      );

      const x =
        animation.fromX
        + (animation.toX - animation.fromX)
          * t;

      const y =
        animation.fromY
        + (animation.toY - animation.fromY)
          * t;

      ctx.globalAlpha =
        1 - t * 0.25;

      ctx.fillStyle = '#efeee8';
      ctx.fillRect(
        x,
        y,
        4,
        4,
      );

      ctx.fillStyle =
        animation.color;

      ctx.fillRect(
        x - 1,
        y + 5,
        6,
        7,
      );

      ctx.globalAlpha = 1;
    }
  }

  #drawFarePopups(ctx) {
    for (const popup of this.farePopups) {
      const t = clamp(
        popup.age / popup.duration,
        0,
        1,
      );

      ctx.globalAlpha =
        1 - t;

      ctx.fillStyle = '#b9ff8b';
      ctx.font =
        '11px "Lucida Console", monospace';
      ctx.textAlign = 'left';

      ctx.fillText(
        `+$${popup.value.toFixed(0)}`,
        popup.x,
        popup.y - t * 18,
      );

      ctx.globalAlpha = 1;
    }
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
