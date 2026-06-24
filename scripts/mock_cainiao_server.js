#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const os = require('os');
const { execFile, execFileSync } = require('child_process');
const path = require('path');

const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_WS_PORT = 13528;
const DEFAULT_HTTP_PORT = 13525;
const DEFAULT_PREVIEW_DIR = '/Users/amo/cainiao-x-print/preview';
const DEFAULT_PID_FILE = '/Users/amo/project/Tabooprint/.cainiao-mock.pid';
const DEFAULT_PRINTER_NAME = 'TAOBAO';
const DEFAULT_RENDERER = path.join(__dirname, 'render_waybill_pdf.py');
const DEFAULT_RENDERED_DIR = path.join(os.tmpdir(), 'tabooprint', 'waybills');
const EVENT_PREFIX = '[cainiao-mock:event]';

const args = parseArgs(process.argv.slice(2));
const host = args.host || DEFAULT_HOST;
const wsPort = Number(args['ws-port'] || DEFAULT_WS_PORT);
const httpPort = Number(args['http-port'] || DEFAULT_HTTP_PORT);
const forcePreview = args['force-preview'] !== 'false';
const mockPhysical = args['mock-physical'] === 'true';
const autoOpenPreview = args['auto-open-preview'] !== 'false';
const failureMode = args['fail'] || 'none';
const pidFile = args['pid-file'] || DEFAULT_PID_FILE;
const previewPdf = resolvePreviewPdf(args.pdf);
const printDryRun = args['print-dry-run'] !== 'false';
const configuredPrinterName = args['printer-name'] || '';
const printMedia = args['print-media'] || '';
const printFitToPage = args['print-fit-to-page'] !== 'false';
const lprBin = args['lpr-bin'] || '/usr/bin/lpr';
const rendererBin = args['renderer-bin'] || '/Users/amo/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3';
const rendererScript = args['renderer-script'] || DEFAULT_RENDERER;
const renderedDir = args['rendered-dir'] || DEFAULT_RENDERED_DIR;
const printDedupe = args['print-dedupe'] !== 'false';
const dedupeWindowMs = Math.max(0, Number(args['dedupe-window-ms'] || 10 * 60 * 1000));

const httpServer = http.createServer(handleHttp);
const wsServer = http.createServer();
const sockets = new Set();
const physicalPrintHistory = new Map();
let activeConnections = 0;

httpServer.listen(httpPort, host, () => {
  log(`HTTP preview server listening on http://${host}:${httpPort}/file/mock.pdf`);
  log(`Serving preview PDF: ${previewPdf ? previewPdf : 'built-in minimal PDF'}`);
});

wsServer.on('upgrade', handleUpgrade);
wsServer.listen(wsPort, host, () => {
  log(`WebSocket mock listening on ws://${host}:${wsPort}/`);
  log(`Mode: ${forcePreview ? 'force previewURL for print commands' : 'respect task.preview'}`);
  log(`Physical mode: ${mockPhysical ? 'enabled' : 'preview=false only'}`);
  log(`Print pipeline: ${printDryRun ? 'dry-run' : 'REAL LPR'} printer=${configuredPrinterName || '(task/default)'} media=${printMedia || '(default)'}`);
  log(`Print dedupe: ${printDedupe ? `enabled window=${dedupeWindowMs}ms` : 'disabled'}`);
  log(`Waybill renderer: ${rendererScript} -> ${renderedDir}`);
  log(`Failure mode: ${failureMode}`);
  writePidFile(pidFile);
});

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const item = argv[i];
    if (!item.startsWith('--')) continue;
    const key = item.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) {
      out[key] = 'true';
    } else {
      out[key] = next;
      i += 1;
    }
  }
  return out;
}

function resolvePreviewPdf(explicitPath) {
  if (explicitPath && fs.existsSync(explicitPath)) return path.resolve(explicitPath);
  if (!fs.existsSync(DEFAULT_PREVIEW_DIR)) return null;

  const pdfs = fs.readdirSync(DEFAULT_PREVIEW_DIR)
    .filter((name) => name.toLowerCase().endsWith('.pdf'))
    .map((name) => path.join(DEFAULT_PREVIEW_DIR, name))
    .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);

  return pdfs[0] || null;
}

function resolveRenderedPdf(pathname) {
  if (!pathname.startsWith('/file/')) return null;
  const rawName = pathname.slice('/file/'.length);
  if (rawName.includes('/')) return null;
  const name = decodeURIComponent(rawName);
  if (!name || !name.toLowerCase().endsWith('.pdf')) return null;
  const base = path.resolve(renderedDir);
  const file = path.resolve(base, name);
  if (!file.startsWith(base + path.sep)) return null;
  return fs.existsSync(file) ? file : null;
}

function handleHttp(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || `${host}:${httpPort}`}`);
  res.setHeader('Access-Control-Allow-Origin', '*');

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
      'Access-Control-Allow-Headers': '*',
    });
    res.end();
    return;
  }

  if (!url.pathname.startsWith('/file/')) {
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('not found');
    return;
  }

  const renderedPdf = resolveRenderedPdf(url.pathname);
  const body = renderedPdf
    ? fs.readFileSync(renderedPdf)
    : previewPdf ? fs.readFileSync(previewPdf) : minimalPdf();
  res.writeHead(200, {
    'content-type': 'application/pdf',
    'content-length': body.length,
    'cache-control': 'no-store',
  });
  if (req.method === 'HEAD') {
    res.end();
  } else {
    res.end(body);
  }
}

function handleUpgrade(req, socket) {
  const key = req.headers['sec-websocket-key'];
  if (!key) {
    socket.write('HTTP/1.1 400 Bad Request\r\n\r\nmissing sec-websocket-key');
    socket.destroy();
    return;
  }

  const accept = crypto
    .createHash('sha1')
    .update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    .digest('base64');

  socket.write([
    'HTTP/1.1 101 Switching Protocols',
    'Upgrade: websocket',
    'Connection: Upgrade',
    `Sec-WebSocket-Accept: ${accept}`,
    '\r\n',
  ].join('\r\n'));

  sockets.add(socket);
  const conn = { socket, buffer: Buffer.alloc(0), closed: false };
  activeConnections += 1;
  logEvent('connection', {
    phase: 'open',
    activeConnections,
  });
  socket.on('data', (chunk) => readFrames(conn, chunk));
  socket.on('close', () => closeConnection('close'));
  socket.on('error', () => closeConnection('error'));

  function closeConnection(reason) {
    if (conn.closed) return;
    conn.closed = true;
    sockets.delete(socket);
    activeConnections = Math.max(0, activeConnections - 1);
    logEvent('connection', {
      phase: 'close',
      reason,
      activeConnections,
    });
  }
}

function readFrames(conn, chunk) {
  conn.buffer = Buffer.concat([conn.buffer, chunk]);

  while (conn.buffer.length >= 2) {
    const first = conn.buffer[0];
    const second = conn.buffer[1];
    const opcode = first & 0x0f;
    const masked = Boolean(second & 0x80);
    let length = second & 0x7f;
    let offset = 2;

    if (length === 126) {
      if (conn.buffer.length < offset + 2) return;
      length = conn.buffer.readUInt16BE(offset);
      offset += 2;
    } else if (length === 127) {
      if (conn.buffer.length < offset + 8) return;
      const bigLength = conn.buffer.readBigUInt64BE(offset);
      if (bigLength > BigInt(Number.MAX_SAFE_INTEGER)) {
        closeSocket(conn, 1009, 'message too large');
        return;
      }
      length = Number(bigLength);
      offset += 8;
    }

    const maskOffset = offset;
    const payloadOffset = offset + (masked ? 4 : 0);
    const frameLength = payloadOffset + length;
    if (conn.buffer.length < frameLength) return;

    let payload = conn.buffer.subarray(payloadOffset, frameLength);
    if (masked) {
      const mask = conn.buffer.subarray(maskOffset, maskOffset + 4);
      payload = Buffer.from(payload);
      for (let i = 0; i < payload.length; i += 1) {
        payload[i] ^= mask[i % 4];
      }
    }

    conn.buffer = conn.buffer.subarray(frameLength);

    if (opcode === 0x8) {
      closeSocket(conn, 1000, 'bye');
      return;
    }
    if (opcode === 0x9) {
      sendFrame(conn.socket, payload, 0xA);
      continue;
    }
    if (opcode !== 0x1) continue;

    handleTextFrame(conn, payload.toString('utf8'));
  }
}

function handleTextFrame(conn, text) {
  let payload;
  try {
    payload = JSON.parse(text);
  } catch (error) {
    sendJson(conn.socket, {
      cmd: 'unknown',
      status: 'failed',
      msg: `invalid json: ${error.message}`,
      errorCode: 400,
    });
    return;
  }

  const cmd = payload.cmd || 'unknown';
  const requestID = payload.requestID || `MOCK_${Date.now()}`;
  log(`recv cmd=${cmd} requestID=${requestID}`);

  if (cmd === 'getPrinters') {
    const discovered = discoverPrinters();
    const defaultPrinter = configuredPrinterName || discovered.defaultPrinter || DEFAULT_PRINTER_NAME;
    const printers = discovered.printers.length > 0
      ? ensurePrinter(discovered.printers, defaultPrinter)
      : ensurePrinter([], defaultPrinter);

    sendJson(conn.socket, {
      cmd,
      requestID,
      status: 'success',
      msg: 'no error',
      defaultPrinter,
      printers,
      errorCode: 0,
    });
    return;
  }

  if (cmd === 'getAgentInfo') {
    sendJson(conn.socket, {
      cmd,
      requestID,
      status: 'success',
      msg: 'no error',
      version: '1.5.3.0',
      errorCode: 0,
    });
    return;
  }

  if (cmd === 'getGlobalConfig') {
    sendJson(conn.socket, {
      cmd,
      requestID,
      status: 'success',
      msg: 'no error',
      notifyOnTaskFailure: true,
      ignoreFontCanNotDisplay: true,
      errorCode: 0,
    });
    return;
  }

  if (cmd === 'setGlobalConfig') {
    sendJson(conn.socket, {
      cmd,
      requestID,
      status: 'success',
      msg: 'no error',
      errorCode: 0,
    });
    return;
  }

  if (cmd === 'setPrinterConfig') {
    sendJson(conn.socket, {
      cmd,
      requestID,
      status: 'success',
      msg: 'no error',
      printer: payload.printer && payload.printer.name ? payload.printer.name : 'TAOBAO',
      errorCode: 0,
    });
    return;
  }

  if (cmd === 'print') {
    handlePrint(conn.socket, payload);
    return;
  }

  sendJson(conn.socket, {
    cmd,
    requestID,
    status: 'failed',
    msg: `unsupported cmd: ${cmd}`,
    errorCode: 404,
  });
}

function handlePrint(socket, payload) {
  const task = payload.task || {};
  const requestID = payload.requestID || `MOCK_${Date.now()}`;
  const taskID = task.taskID || requestID;
  const printer = task.printer || 'TAOBAO';
  const documents = Array.isArray(task.documents) ? task.documents : [];
  const runtimeMode = describeRuntimeMode();

  logEvent('task', {
    phase: 'start',
    command: 'print',
    requestID,
    taskID,
    printer,
    documentCount: documents.length,
    mode: runtimeMode,
  });

  if (!documents.length) {
    logEvent('task', {
      phase: 'finish',
      command: 'print',
      requestID,
      taskID,
      printer,
      documentCount: 0,
      mode: runtimeMode,
      result: 'document-not-found',
      errorCode: 11,
    });
    sendJson(socket, documentNotFoundResponse(requestID, taskID));
    return;
  }

  const docs = documents.map((doc, index) => ({
    documentId: String(doc.documentID || doc.documentId || `MOCK_DOC_${index + 1}`),
    fingerprint: buildDocumentFingerprint(doc),
    index,
  }));
  const shouldReturnPreview = forcePreview || task.preview === true;
  const physicalMode = mockPhysical || task.preview === false;
  const spendTime = { total: 220, downloading: 15, pending: 45, rendering: 160 };
  const renderedWaybill = renderWaybillPdf(payload, requestID, taskID);
  const printablePdf = renderedWaybill.ok ? renderedWaybill.path : previewPdf;
  const previewName = renderedWaybill.ok ? renderedWaybill.fileName : `mock_${Date.now()}_0_0.pdf`;
  const previewURL = `http://localhost:${httpPort}/file/${previewName}`;
  let physicalPrintJob = null;

  if (failureMode === 'document-not-found') {
    logEvent('task', {
      phase: 'finish',
      command: 'print',
      requestID,
      taskID,
      printer,
      documentCount: documents.length,
      mode: runtimeMode,
      result: 'document-not-found',
      errorCode: 11,
    });
    sendJson(socket, documentNotFoundResponse(requestID, taskID));
    return;
  }

  const flow = [
    {
      delay: 0,
      message: {
        cmd: 'notifyTaskResult',
        requestID,
        status: 'initial',
        printer,
        taskId: taskID,
      },
    },
    {
      delay: 15,
      message: {
        cmd: 'print',
        requestID,
        taskID,
        status: 'success',
        msg: 'no error',
        errorCode: 0,
      },
    },
  ];

  if (failureMode === 'decrypt') {
    docs.forEach((doc, docIndex) => {
      flow.push({
        delay: 50 + docIndex * 20,
        message: decryptFailureResponse(requestID, taskID, printer, doc.documentId),
      });
    });
    flow.forEach((item) => {
      setTimeout(() => sendJson(socket, item.message), item.delay);
    });
    logEvent('task', {
      phase: 'finish',
      command: 'print',
      requestID,
      taskID,
      printer,
      documentCount: docs.length,
      mode: runtimeMode,
      result: 'decrypt-failure',
      errorCode: 40,
    });
    return;
  }

  docs.forEach((doc, docIndex) => {
    flow.push({
      delay: 50 + docIndex * 20,
      message: {
        cmd: 'notifyDocResult',
        requestID,
        status: 'rendered',
        printer,
        taskId: taskID,
        documentId: doc.documentId,
        code: 0,
        detail: 'success',
      },
    });
    flow.push({
      delay: 85 + docIndex * 20,
      message: {
        cmd: 'notifyDocResult',
        requestID,
        status: 'printed',
        printer,
        taskId: taskID,
        documentId: doc.documentId,
        code: 0,
        detail: 'success',
        spendTime,
      },
    });
  });

  if (shouldReturnPreview) {
    flow.push({
      delay: 130,
      message: {
        cmd: 'print',
        requestID,
        taskID,
        status: 'success',
        msg: 'no error',
        responses: docs.map((doc) => ({
          documentId: doc.documentId,
          urls: [previewURL],
        })),
        previewURL,
      },
    });
    if (autoOpenPreview) {
      setTimeout(() => {
        openPreview(previewURL);
      }, 350);
    }
  } else if (physicalMode) {
    physicalPrintJob = submitPhysicalPrint({
      requestID,
      taskID,
      taskPrinter: printer,
      docs,
      pdfPath: printablePdf,
    });
    flow.push({
      delay: 130,
      message: physicalPrintJob.ok
        ? buildNotifyPrintResult(requestID, taskID, physicalPrintJob.printerName, docs, spendTime)
        : buildNotifyPrintFailureResult(requestID, taskID, physicalPrintJob.printerName, docs, physicalPrintJob.error),
    });
  }

  const docsMap = {};
  docs.forEach((doc) => {
    docsMap[doc.documentId] = {
      cmd: 'notifyDocResult',
      requestID,
      status: 'printed',
      printer,
      taskId: taskID,
      documentId: doc.documentId,
      code: 0,
      detail: 'success',
      spendTime,
    };
  });

  flow.push({
    delay: shouldReturnPreview || physicalMode ? 240 : 170,
    message: {
      cmd: 'notifyTaskResult',
      requestID,
      status: physicalPrintJob && !physicalPrintJob.ok ? 'completeFailed' : 'completeSuccess',
      printer,
      taskId: taskID,
      spendTime,
      docs: docsMap,
    },
  });

  logEvent('task', {
    phase: 'finish',
    command: 'print',
    requestID,
    taskID,
    printer,
    documentCount: docs.length,
    mode: runtimeMode,
    result: describeTaskResult(shouldReturnPreview, physicalPrintJob),
    previewURL: shouldReturnPreview ? previewURL : undefined,
    renderedPdf: renderedWaybill.ok ? renderedWaybill.path : undefined,
    renderError: renderedWaybill.ok ? undefined : renderedWaybill.error,
    printDryRun: physicalPrintJob ? physicalPrintJob.dryRun : undefined,
    printCommand: physicalPrintJob ? physicalPrintJob.commandText : undefined,
    printError: physicalPrintJob ? physicalPrintJob.error : undefined,
  });

  flow.forEach((item) => {
    setTimeout(() => sendJson(socket, item.message), item.delay);
  });
}

function documentNotFoundResponse(requestID, taskID) {
  return {
    cmd: 'print',
    requestID,
    taskID,
    status: 'failed',
    msg: 'document not found',
    errorCode: 11,
  };
}

function discoverPrinters() {
  try {
    const output = execFileSync('/usr/bin/lpstat', ['-p', '-d'], {
      encoding: 'utf8',
      timeout: 3000,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const printers = [];
    let defaultPrinter = '';
    output.split(/\r?\n/).forEach((line) => {
      const printerMatch = line.match(/^printer\s+(\S+)\s+/)
        || line.match(/^打印机\s*([^，\s]+?)(?:闲置|正在|已禁用|停用|，|\s|$)/);
      if (printerMatch) {
        printers.push(buildPrinterInfo(printerMatch[1], !/disabled|已禁用/i.test(line)));
      }
      const defaultMatch = line.match(/(?:system default destination|系统默认目的位置)[：:]?\s*(\S+)/i);
      if (defaultMatch) {
        defaultPrinter = defaultMatch[1];
      }
    });
    return { printers, defaultPrinter };
  } catch (error) {
    log(`lpstat printer discovery failed: ${error.message}`);
    return { printers: [], defaultPrinter: '' };
  }
}

function ensurePrinter(printers, printerName) {
  const hasPrinter = printers.some((printer) => printer.name === printerName);
  return hasPrinter ? printers : [buildPrinterInfo(printerName, true), ...printers];
}

function buildPrinterInfo(name, enabled) {
  return {
    name,
    status: enabled ? 'enable' : 'disable',
    type: 'RAW',
    printerType: 'NORMAL',
    supportRfid: false,
  };
}

function renderWaybillPdf(payload, requestID, taskID) {
  try {
    fs.mkdirSync(renderedDir, { recursive: true });
    const stdout = execFileSync(rendererBin, [
      rendererScript,
      '--input', '-',
      '--output-dir', renderedDir,
      '--request-id', requestID,
      '--task-id', taskID,
    ], {
      input: JSON.stringify(payload),
      encoding: 'utf8',
      timeout: 10000,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const result = JSON.parse(String(stdout).trim());
    if (!result.ok || !result.path || !fs.existsSync(result.path)) {
      throw new Error(`renderer returned no PDF: ${String(stdout).trim()}`);
    }
    logEvent('render', {
      phase: 'success',
      requestID,
      taskID,
      pdfPath: result.path,
      fileName: result.fileName,
      documentIds: result.documentIds,
    });
    return {
      ok: true,
      path: result.path,
      fileName: result.fileName || path.basename(result.path),
    };
  } catch (error) {
    const stderr = error.stderr ? String(error.stderr).trim() : '';
    const message = stderr || error.message;
    logEvent('render', {
      phase: 'failed',
      requestID,
      taskID,
      error: message,
      fallbackPdf: previewPdf || undefined,
    });
    return {
      ok: false,
      error: message,
    };
  }
}

function submitPhysicalPrint({ requestID, taskID, taskPrinter, docs, pdfPath }) {
  const printerName = configuredPrinterName || taskPrinter || DEFAULT_PRINTER_NAME;
  const printablePdf = pdfPath || writeMinimalPdf(requestID, taskID);
  const lprArgs = buildLprArgs(printerName, printablePdf);
  const commandText = [lprBin, ...lprArgs].map(shellDisplay).join(' ');
  const dedupeKey = buildPhysicalPrintDedupeKey({ printerName, docs });
  const duplicate = findDuplicatePhysicalPrint(dedupeKey);

  if (duplicate) {
    logEvent('print-job', {
      phase: 'duplicate-suppressed',
      command: 'lpr',
      requestID,
      taskID,
      printer: printerName,
      documentCount: docs.length,
      pdfPath: printablePdf,
      previousPdfPath: duplicate.pdfPath,
      previousRequestID: duplicate.requestID,
      previousTaskID: duplicate.taskID,
      previousCommandText: duplicate.commandText,
      duplicateAgeMs: Date.now() - duplicate.timestamp,
      dedupeKey,
    });
    return {
      ok: true,
      dryRun: duplicate.dryRun,
      duplicate: true,
      printerName,
      commandText: duplicate.commandText || commandText,
      pdfPath: duplicate.pdfPath || printablePdf,
    };
  }

  logEvent('print-job', {
    phase: printDryRun ? 'dry-run' : 'submit',
    command: 'lpr',
    requestID,
    taskID,
    printer: printerName,
    documentCount: docs.length,
    pdfPath: printablePdf,
    commandText,
    media: printMedia || undefined,
  });

  if (printDryRun) {
    rememberPhysicalPrint(dedupeKey, {
      requestID,
      taskID,
      printerName,
      commandText,
      pdfPath: printablePdf,
      dryRun: true,
      documentIds: docs.map((doc) => doc.documentId),
    });
    return {
      ok: true,
      dryRun: true,
      printerName,
      commandText,
      pdfPath: printablePdf,
    };
  }

  try {
    execFileSync(lprBin, lprArgs, {
      encoding: 'utf8',
      timeout: 15000,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    logEvent('print-job', {
      phase: 'submitted',
      command: 'lpr',
      requestID,
      taskID,
      printer: printerName,
      documentCount: docs.length,
      pdfPath: printablePdf,
      commandText,
    });
    rememberPhysicalPrint(dedupeKey, {
      requestID,
      taskID,
      printerName,
      commandText,
      pdfPath: printablePdf,
      dryRun: false,
      documentIds: docs.map((doc) => doc.documentId),
    });
    return {
      ok: true,
      dryRun: false,
      printerName,
      commandText,
      pdfPath: printablePdf,
    };
  } catch (error) {
    const stderr = error.stderr ? String(error.stderr).trim() : '';
    const message = stderr || error.message;
    logEvent('print-job', {
      phase: 'failed',
      command: 'lpr',
      requestID,
      taskID,
      printer: printerName,
      documentCount: docs.length,
      pdfPath: printablePdf,
      commandText,
      error: message,
    });
    return {
      ok: false,
      dryRun: false,
      printerName,
      commandText,
      pdfPath: printablePdf,
      error: message,
    };
  }
}

function buildPhysicalPrintDedupeKey({ printerName, docs }) {
  const docIds = docs.map((doc) => doc.documentId).join(',');
  const docFingerprints = docs.map((doc) => doc.fingerprint || doc.documentId).join(',');
  return [
    'physical',
    printerName,
    printMedia || '(default-media)',
    printFitToPage ? 'fit' : 'nofit',
    docIds,
    docFingerprints,
  ].join('|');
}

function buildDocumentFingerprint(document) {
  const parts = [];
  parts.push(String(document.documentID || document.documentId || ''));
  const contents = Array.isArray(document.contents) ? document.contents : [];
  contents.forEach((content) => {
    if (!content || typeof content !== 'object') return;
    if (content.encryptedData) parts.push(`encrypted:${content.ver || ''}:${content.templateURL || ''}:${hashText(content.encryptedData)}`);
    if (content.data && typeof content.data === 'object') {
      const data = content.data;
      parts.push(`custom-template:${content.templateURL || ''}`);
      [
        'ORDER_ID',
        'WAIBILLNO_BAR_CODE',
        'ITEM_INFO',
        'ITEM_TOTAL_COUNT',
        'SELLER_MEMO',
        'BUYER_MEMO',
      ].forEach((key) => {
        if (data[key] !== undefined && data[key] !== null) parts.push(`${key}:${String(data[key])}`);
      });
    }
  });
  return hashText(parts.join('|'));
}

function hashText(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex').slice(0, 16);
}

function findDuplicatePhysicalPrint(dedupeKey) {
  if (!printDedupe || dedupeWindowMs <= 0) return null;
  const now = Date.now();
  purgePhysicalPrintHistory(now);
  const existing = physicalPrintHistory.get(dedupeKey);
  if (!existing) return null;
  if (now - existing.timestamp > dedupeWindowMs) {
    physicalPrintHistory.delete(dedupeKey);
    return null;
  }
  return existing;
}

function rememberPhysicalPrint(dedupeKey, details) {
  if (!printDedupe || dedupeWindowMs <= 0) return;
  const now = Date.now();
  purgePhysicalPrintHistory(now);
  physicalPrintHistory.set(dedupeKey, {
    timestamp: now,
    ...details,
  });
}

function purgePhysicalPrintHistory(now = Date.now()) {
  if (dedupeWindowMs <= 0) {
    physicalPrintHistory.clear();
    return;
  }
  for (const [key, item] of physicalPrintHistory.entries()) {
    if (now - item.timestamp > dedupeWindowMs) {
      physicalPrintHistory.delete(key);
    }
  }
}

function buildLprArgs(printerName, pdfPath) {
  const lprArgs = ['-P', printerName];
  if (printMedia) {
    lprArgs.push('-o', `media=${printMedia}`);
  }
  if (printFitToPage) {
    lprArgs.push('-o', 'fit-to-page');
  }
  lprArgs.push(pdfPath);
  return lprArgs;
}

function writeMinimalPdf(requestID, taskID) {
  const safeName = String(taskID || requestID || Date.now()).replace(/[^A-Za-z0-9_.-]/g, '_');
  const dir = path.join(os.tmpdir(), 'tabooprint');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${safeName}.pdf`);
  fs.writeFileSync(file, minimalPdf());
  return file;
}

function shellDisplay(value) {
  const text = String(value);
  return /^[A-Za-z0-9_./:=+-]+$/.test(text) ? text : `'${text.replace(/'/g, "'\\''")}'`;
}

function decryptFailureResponse(requestID, taskID, printer, documentId) {
  return {
    cmd: 'notifyDocResult',
    requestID,
    status: 'rendered',
    printer,
    taskId: taskID,
    documentId,
    code: 40,
    detail: 'Unknown encryption type.',
    from: {
      source: 'decrypt',
    },
  };
}

function buildNotifyPrintFailureResult(requestID, taskID, printer, docs, error) {
  return {
    cmd: 'notifyPrintResult',
    requestID,
    taskID,
    status: 1,
    msg: error || 'print failed',
    taskStatus: 'failed',
    printer,
    printStatus: docs.map((doc) => ({
      documentID: doc.documentId,
      detail: error || 'print failed',
      msg: error || 'print failed',
      printer,
      status: 'failed',
    })),
  };
}

function buildNotifyPrintResult(requestID, taskID, printer, docs, spendTime) {
  return {
    cmd: 'notifyPrintResult',
    requestID,
    taskID,
    status: 0,
    msg: 'no error',
    taskStatus: 'printed',
    printer,
    evaluationSpendTime: spendTime.rendering,
    pendingSpendTime: spendTime.pending,
    downloadingSpendTime: spendTime.downloading,
    totalSpendTime: spendTime.total,
    printStatus: docs.map((doc) => ({
      documentID: doc.documentId,
      detail: '',
      msg: 'no error',
      printer,
      renderingSpendTime: spendTime.rendering,
      renderingStartTime: nowTimestamp(),
      status: 'success',
    })),
  };
}

function describeTaskResult(shouldReturnPreview, physicalPrintJob) {
  if (shouldReturnPreview) return 'preview';
  if (!physicalPrintJob) return 'notifyPrintResult';
  if (!physicalPrintJob.ok) return 'physical-print-failed';
  if (physicalPrintJob.duplicate) return 'physical-duplicate-suppressed';
  return physicalPrintJob.dryRun ? 'physical-dry-run' : 'physical-print';
}

function sendJson(socket, obj) {
  log(`send cmd=${obj.cmd} requestID=${obj.requestID || ''} status=${obj.status || ''}`);
  sendFrame(socket, Buffer.from(JSON.stringify(obj), 'utf8'), 0x1);
}

function describeRuntimeMode() {
  if (failureMode === 'document-not-found') return 'failure-document-not-found';
  if (failureMode === 'decrypt') return 'failure-decrypt';
  if (forcePreview) return 'default-preview';
  return 'respect-preview-flag';
}

function sendFrame(socket, payload, opcode) {
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x80 | opcode, payload.length]);
  } else if (payload.length <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  socket.write(Buffer.concat([header, payload]));
}

function closeSocket(conn, code, reason) {
  if (conn.closed) return;
  conn.closed = true;
  const reasonBytes = Buffer.from(reason || '');
  const payload = Buffer.alloc(2 + reasonBytes.length);
  payload.writeUInt16BE(code, 0);
  reasonBytes.copy(payload, 2);
  try {
    sendFrame(conn.socket, payload, 0x8);
  } catch (_) {
    // Ignore close write failures.
  }
  conn.socket.end();
}

function minimalPdf() {
  return Buffer.from([
    '%PDF-1.4',
    '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj',
    '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj',
    '3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 300 144] /Contents 4 0 R >> endobj',
    '4 0 obj << /Length 44 >> stream',
    'BT /F1 18 Tf 36 72 Td (Cainiao Mock PDF) Tj ET',
    'endstream endobj',
    'xref',
    '0 5',
    '0000000000 65535 f ',
    'trailer << /Root 1 0 R /Size 5 >>',
    'startxref',
    '0',
    '%%EOF',
  ].join('\n'));
}

function openPreview(url) {
  execFile('open', [url], { timeout: 5000 }, (error) => {
    if (error) {
      log(`auto-open preview failed: ${error.message}`);
    } else {
      log(`auto-opened preview: ${url}`);
    }
  });
}

function nowTimestamp() {
  const d = new Date();
  const pad = (n, width = 2) => String(n).padStart(width, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`;
}

function shutdown() {
  log('shutting down');
  try {
    if (fs.existsSync(pidFile)) fs.unlinkSync(pidFile);
  } catch (_) {}
  for (const socket of sockets) socket.destroy();
  wsServer.close();
  httpServer.close();
  setTimeout(() => process.exit(0), 100).unref();
}

function writePidFile(file) {
  try {
    fs.writeFileSync(file, String(process.pid));
  } catch (error) {
    log(`pid file write failed: ${error.message}`);
  }
}

function log(message) {
  process.stdout.write(`[cainiao-mock] ${message}\n`);
}

function logEvent(type, details) {
  process.stdout.write(`${EVENT_PREFIX} ${JSON.stringify({
    type,
    time: nowTimestamp(),
    ...details,
  })}\n`);
}
