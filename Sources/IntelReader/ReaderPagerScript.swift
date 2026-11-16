import Foundation

/// The page-flip reader JavaScript. It is injected once per rendered book
/// (after `WKNavigationDelegate.didFinish`) and keeps both reading metrics in
/// sync: `progress` is the paged/scroll fraction the shelf shows and
/// `textProgress` is the extracted-text fraction the phone understands.
enum ReaderPagerScript {
    static func didFinishScript(
        styleScript: String,
        fallbackProgress: Double,
        textFraction: Double?,
        needleLiteral: String,
        hasAnchor: Bool,
        pageMode: String
    ) -> String {
        let textFractionLiteral: String = textFraction.map {
            "\(min(max($0, 0), 1))"
        } ?? "null"
        let hasAnchorLiteral = hasAnchor ? "true" : "false"
        return #"""
(function () {
  \#(styleScript)
  var fallbackProgress = \#(fallbackProgress);
  var initialTextFraction = \#(textFractionLiteral);
  var initialNeedle = \#(needleLiteral);
  var hasAnchor = \#(hasAnchorLiteral);
  var initialPageMode = "\#(pageMode)";
  var readerPager = null;

  var normalize = function (value) {
    return (value || '').replace(/\s+/g, ' ').trim();
  };

  // The phone measures positions in characters, the WebView scrolls
  // by rendered height. Flatten the rendered page back into text -
  // inserting the same newlines the sync's text model uses for block
  // boundaries - so the two metrics can be converted exactly.
  var readerTextIndex = null;
  var buildReaderTextIndex = function () {
    if (readerTextIndex) { return readerTextIndex; }
    var root = document.querySelector('.page') || document.body;
    var parts = [];
    var entries = [];
    var starts = new Map();
    var length = 0;
    var blockTags = /^(P|DIV|H1|H2|H3|H4|H5|H6|LI|TR)$/;
    var append = function (value) {
      if (!value) { return; }
      parts.push(value);
      length += value.length;
    };
    var walk = function (element) {
      var child = element.firstChild;
      while (child) {
        if (child.nodeType === 3) {
          var nodeValue = child.nodeValue || '';
          if (nodeValue.length > 0) {
            entries.push({ node: child, start: length });
            starts.set(child, length);
            append(nodeValue);
          }
        } else if (child.nodeType === 1) {
          var tag = child.tagName;
          if (tag !== 'SCRIPT' && tag !== 'STYLE' && tag !== 'NOSCRIPT' && tag !== 'TEMPLATE') {
            if (tag === 'BR') {
              append('\n');
            } else {
              walk(child);
              if (blockTags.test(tag)) {
                // TXT paragraphs were split at blank lines for layout; give
                // each paragraph the same two newlines the raw text had so
                // textProgress keeps matching the sync's character model.
                append(tag === 'P' && root.classList && root.classList.contains('txt') ? '\n\n' : '\n');
              }
            }
          }
        }
        child = child.nextSibling;
      }
    };
    walk(root);
    readerTextIndex = { entries: entries, starts: starts, length: length };
    return readerTextIndex;
  };

  // The first line of a page does not always start right under the top
  // margin: headings and paragraph margins push it down a little. Offer
  // several candidate points so the caret probe lands inside the first
  // line even when its text starts with an indent.
  var readerTopPoints = function () {
    if (readerPager) {
      var pagedPoints = readerPager.topPoints ? readerPager.topPoints() : null;
      if (pagedPoints && pagedPoints.length) { return pagedPoints; }
      var pagedPoint = readerPager.topPoint();
      if (pagedPoint) { return [pagedPoint]; }
    }
    var root = document.querySelector('.page') || document.body;
    var rootRect = root.getBoundingClientRect();
    return [{
      x: Math.min(window.innerWidth - 8, Math.max(8, rootRect.left + 48)),
      y: 16
    }];
  };

  var readerTopRange = function () {
    var points = readerTopPoints();
    var first = null;
    for (var i = 0; i < points.length; i++) {
      var range = document.caretRangeFromPoint
        ? document.caretRangeFromPoint(points[i].x, points[i].y)
        : null;
      if (!range || !range.startContainer) { continue; }
      if (!first) { first = range; }
      if (range.startContainer.nodeType === 3) { return range; }
    }
    return first;
  };

  var textRectForFraction = function (fraction) {
    var index = buildReaderTextIndex();
    if (index.length <= 0 || !index.entries.length) { return null; }
    var clamped = Math.min(Math.max(fraction, 0), 1);
    var target = Math.round(clamped * (index.length - 1));
    var entries = index.entries;
    var lo = 0;
    var hi = entries.length - 1;
    var best = entries[0];
    while (lo <= hi) {
      var mid = Math.floor((lo + hi) / 2);
      if (entries[mid].start <= target) {
        best = entries[mid];
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    var nodeValue = best.node.nodeValue || '';
    if (!nodeValue.length) { return null; }
    var offset = Math.min(Math.max(target - best.start, 0), nodeValue.length - 1);
    try {
      var range = document.createRange();
      range.setStart(best.node, offset);
      range.setEnd(best.node, Math.min(offset + 1, nodeValue.length));
      var rect = range.getBoundingClientRect();
      if (rect && rect.height > 0) {
        return rect;
      }
      var parent = best.node.parentElement;
      if (parent) {
        return parent.getBoundingClientRect();
      }
    } catch (e) {}
    return null;
  };

  var textFractionAtTop = function () {
    var index = buildReaderTextIndex();
    if (index.length <= 0) { return null; }
    var range = readerTopRange();
    if (!range || !range.startContainer) { return null; }
    var node = range.startContainer;
    if (node.nodeType !== 3) {
      var walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT, null);
      node = walker.nextNode();
      if (!node) { return null; }
      var nodeStart = index.starts.get(node);
      if (nodeStart === undefined) { return null; }
      return Math.min(1, Math.max(0, nodeStart / index.length));
    }
    var start = index.starts.get(node);
    if (start === undefined) { return null; }
    var offset = start + range.startOffset;
    return Math.min(1, Math.max(0, offset / index.length));
  };

  var topSnippet = function () {
    var range = readerTopRange();
    if (!range || !range.startContainer || range.startContainer.nodeType !== 3) {
      return '';
    }
    var node = range.startContainer;
    var value = node.nodeValue || '';
    var start = range.startOffset;
    while (start < value.length && /\s/.test(value.charAt(start))) { start++; }
    var out = value.slice(start, start + 12);
    if (out.replace(/\s+/g, '').length < 4) {
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
      walker.currentNode = node;
      out = '';
      var offset = start;
      var current = node;
      while (current && out.length < 12) {
        out += (current.nodeValue || '').slice(offset);
        offset = 0;
        var next = walker.nextNode();
        if (next && current.parentElement !== next.parentElement) { out += ' '; }
        current = next;
      }
    }
    return out.replace(/\s+/g, ' ').trim().slice(0, 12);
  };

  var textRect = function (element, rawIndex, length) {
    var walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT, null);
    var consumed = 0;
    var startNode = null;
    var startOffset = 0;
    var endNode = null;
    var endOffset = 0;
    var node;
    while ((node = walker.nextNode())) {
      var len = node.nodeValue ? node.nodeValue.length : 0;
      if (!startNode && rawIndex < consumed + len) {
        startNode = node;
        startOffset = rawIndex - consumed;
      }
      if (startNode && rawIndex + length <= consumed + len) {
        endNode = node;
        endOffset = rawIndex + length - consumed;
        break;
      }
      consumed += len;
    }
    if (!startNode || !endNode) { return null; }
    try {
      var range = document.createRange();
      range.setStart(startNode, startOffset);
      range.setEnd(endNode, endOffset);
      return range.getBoundingClientRect();
    } catch (e) {
      return null;
    }
  };

  var elementTextFraction = function (element, rawIndex) {
    var index = buildReaderTextIndex();
    if (index.length <= 0) { return null; }
    var walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT, null);
    var first = walker.nextNode();
    if (!first) { return null; }
    var start = index.starts.get(first);
    if (start === undefined) { return null; }
    return Math.min(1, Math.max(0, (start + rawIndex) / index.length));
  };

  var anchorRect = function (needle, expected) {
    var target = normalize(needle);
    if (!target) { return null; }
    var nodes = document.querySelectorAll(
      'article,main,p,li,h1,h2,h3,h4,h5,h6,blockquote,pre,td,section,div'
    );
    var currentMax = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
    var columnPaged = readerPager && readerPager.isColumnPaged();
    var best = null;
    var bestText = '';
    var bestIndex = -1;
    var bestDistance = Infinity;
    for (var i = 0; i < nodes.length; i++) {
      var element = nodes[i];
      var text = normalize(element.innerText || element.textContent || '');
      var index = text.indexOf(target);
      if (index < 0) { continue; }
      var fraction = null;
      if (columnPaged) {
        fraction = elementTextFraction(element, index);
      }
      if (fraction === null) {
        var rect = element.getBoundingClientRect();
        var top = rect.top + window.scrollY;
        var ratio = text.length > 0 ? Math.min(1, index / text.length) : 0;
        var spot = top + rect.height * ratio;
        fraction = Math.min(1, Math.max(0, spot / currentMax));
      }
      var distance = Math.abs(fraction - expected);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = element;
        bestText = text;
        bestIndex = index;
      }
    }
    if (!best) { return null; }
    var raw = best.innerText || best.textContent || '';
    var rawIndex = raw.indexOf(needle);
    if (rawIndex < 0) {
      // Whitespace between the phone text, the extracted text and the
      // rendered HTML can differ. Compare with collapsed whitespace
      // and keep a map back to the raw text offset.
      var collapsedText = '';
      var collapsedMap = [];
      var pendingSpace = false;
      for (var c = 0; c < raw.length; c++) {
        var character = raw.charAt(c);
        if (/\s/.test(character)) {
          if (collapsedText.length > 0) { pendingSpace = true; }
          continue;
        }
        if (pendingSpace) {
          collapsedText += ' ';
          collapsedMap.push(Math.max(c - 1, 0));
          pendingSpace = false;
        }
        collapsedText += character;
        collapsedMap.push(c);
      }
      var collapsedIndex = collapsedText.indexOf(target);
      if (collapsedIndex >= 0) {
        rawIndex = collapsedMap[collapsedIndex];
      }
    }
    if (rawIndex >= 0) {
      var rawLength = 0;
      var counted = 0;
      var previousSpace = false;
      while (rawIndex + rawLength < raw.length && counted < target.length) {
        var current = raw.charAt(rawIndex + rawLength);
        if (/\s/.test(current)) {
          if (!previousSpace) { counted++; previousSpace = true; }
        } else {
          counted++;
          previousSpace = false;
        }
        rawLength++;
      }
      var precise = textRect(best, rawIndex, Math.max(1, rawLength));
      if (precise !== null) { return precise; }
    }
    var rectFallback = best.getBoundingClientRect();
    var textLength = Math.max(1, bestText.length);
    var fallbackRatio = Math.min(1, Math.max(0, bestIndex / textLength));
    return {
      top: rectFallback.top + rectFallback.height * fallbackRatio,
      left: rectFallback.left,
      width: rectFallback.width,
      height: 1
    };
  };

  // MARK: Pager

  readerPager = (function () {
    var P = {};
    var state = {
      mode: initialPageMode,
      wrapper: null,
      viewport: null,
      metrics: null,
      pages: 1,
      page: 0,
      lastTextFraction: null,
      wheelAt: 0,
      reportTimer: null,
      resizeTimer: null,
      verticalRecheckTimer: null,
      verticalRoot: null,
      scrollRoot: null,
      zones: null,
      interactions: false,
      ready: false,
      silent: false
    };

    var ensureStyle = function () {
      if (document.getElementById('intel-pager-style')) { return; }
      var style = document.createElement('style');
      style.id = 'intel-pager-style';
      style.textContent = [
        'html.intel-paged, body.intel-paged { overflow: hidden !important; height: 100% !important; }',
        'body.intel-paged { margin: 0 !important; padding: 0 !important; max-width: none !important; }',
        'html.intel-paged { margin: 0 !important; padding: 0 !important; }',
        'body.intel-paged .intel-paged-root .page, body.intel-paged .intel-paged-root.page { max-width: none !important; margin: 0 !important; padding: 0 !important; }',
        'body.intel-paged .intel-paged-root img { max-height: var(--intel-page-height); width: auto; max-width: 100%; }',
        'body.intel-paged .intel-paged-root pre { white-space: pre-wrap !important; overflow: visible !important; overflow-wrap: break-word; }',
        'body.intel-paged .intel-paged-root pre, body.intel-paged .intel-paged-root img { break-inside: avoid; -webkit-column-break-inside: avoid; }',
        'body.intel-paged .intel-paged-root h1, body.intel-paged .intel-paged-root h2, body.intel-paged .intel-paged-root h3, body.intel-paged .intel-paged-root h4, body.intel-paged .intel-paged-root h5, body.intel-paged .intel-paged-root h6 { break-after: avoid; }',
        '#intel-paged-viewport { scrollbar-width: none; -ms-overflow-style: none; }',
        '#intel-paged-viewport::-webkit-scrollbar { width: 0; height: 0; display: none; }',
        '.intel-turn-zone:hover .intel-turn-arrow { opacity: 0.5 !important; }',
        'html.intel-vertical { overflow-y: auto !important; }',
        'html.intel-vertical body { margin: 0 !important; padding-left: 0 !important; padding-right: 0 !important; padding-bottom: 0 !important; max-width: none !important; }',
        'html.intel-vertical body .page { max-width: none !important; margin-left: 0 !important; margin-right: 0 !important; padding-left: 0 !important; padding-right: 0 !important; padding-bottom: 0 !important; }',
        'html.intel-vertical img { max-height: var(--intel-page-height); width: auto; max-width: 100%; }',
        'html.intel-vertical pre { white-space: pre-wrap !important; overflow: visible !important; overflow-wrap: break-word; }',
        'html.intel-vertical .intel-vertical-column, html.intel-vertical body .intel-vertical-column { box-sizing: content-box !important; width: var(--intel-column-width) !important; margin-left: auto !important; margin-right: auto !important; padding-top: var(--intel-column-top) !important; }',
        // Scroll mode keeps the same text column as the paged modes: the
        // publisher's side padding is dropped and the content is centred at
        // the paged width, so switching modes never rewraps a line.
        'html.intel-scroll body { margin: 0 !important; padding-left: 0 !important; padding-right: 0 !important; max-width: none !important; }',
        'html.intel-scroll body .page { max-width: none !important; margin-left: 0 !important; margin-right: 0 !important; padding-left: 0 !important; padding-right: 0 !important; }',
        'html.intel-scroll .intel-scroll-column, html.intel-scroll body .intel-scroll-column { box-sizing: content-box !important; width: var(--intel-column-width) !important; max-width: var(--intel-column-width) !important; margin-left: auto !important; margin-right: auto !important; padding-top: var(--intel-column-top) !important; padding-bottom: var(--intel-column-bottom) !important; }'
      ].join('\n');
      document.head.appendChild(style);
    };

    var ensureViewport = function () {
      if (state.viewport && document.body.contains(state.viewport)) { return state.viewport; }
      var viewport = document.createElement('div');
      viewport.id = 'intel-paged-viewport';
      viewport.setAttribute('data-intel-overlay', '1');
      viewport.style.cssText =
        'position:fixed;left:0;top:0;width:100%;height:100%;box-sizing:border-box;' +
        'overflow-x:auto;overflow-y:hidden;overscroll-behavior:contain;';
      // The page label must follow native scrolling (smooth turns, any
      // interrupted animation) without re-reporting the reading position.
      viewport.addEventListener('scroll', function () {
        if (state.mode !== 'horizontal' || !state.metrics) { return; }
        var page = Math.round(viewport.scrollLeft / state.metrics.step);
        page = Math.max(0, Math.min(state.pages - 1, page));
        if (page !== state.page) {
          state.page = page;
          postIndicator();
        }
      }, { passive: true });
      document.body.appendChild(viewport);
      state.viewport = viewport;
      return viewport;
    };

    var isOverlayNode = function (node) {
      return node.nodeType === 1 && node.hasAttribute && node.hasAttribute('data-intel-overlay');
    };

    var ensureWrapper = function () {
      if (state.wrapper && document.body.contains(state.wrapper)) {
        var currentViewport = ensureViewport();
        if (state.wrapper.parentNode !== currentViewport) {
          currentViewport.appendChild(state.wrapper);
        }
        return state.wrapper;
      }
      var wrapper = document.createElement('div');
      wrapper.className = 'intel-paged-root';
      var children = Array.prototype.slice.call(document.body.childNodes);
      for (var i = 0; i < children.length; i++) {
        if (isOverlayNode(children[i])) { continue; }
        wrapper.appendChild(children[i]);
      }
      var viewport = ensureViewport();
      viewport.appendChild(wrapper);
      state.wrapper = wrapper;
      return wrapper;
    };

    // WebKit leaves the scroll container's padding out of the scrollable
    // overflow, so the last column could not reach its own left edge.
    // An absolutely positioned spacer after the last column provides the
    // right-hand margin and the missing scroll room.
    var rightSpacer = null;
    var ensureRightSpacer = function (viewport) {
      if (rightSpacer && rightSpacer.parentNode === viewport) { return rightSpacer; }
      rightSpacer = document.createElement('div');
      rightSpacer.setAttribute('data-intel-overlay', '1');
      rightSpacer.style.cssText =
        'position:absolute;top:0;left:0;width:1px;height:1px;pointer-events:none;';
      viewport.appendChild(rightSpacer);
      return rightSpacer;
    };

    var removeRightSpacer = function () {
      if (rightSpacer && rightSpacer.parentNode) {
        rightSpacer.parentNode.removeChild(rightSpacer);
      }
      rightSpacer = null;
    };

    // Vertical pages share the horizontal page frame: the same text column
    // width and the same page height, with the side/top margins left blank.
    // Switching between the two paged modes then keeps the same page of
    // text instead of reflowing to the full window width.
    var applyVerticalFrame = function (metrics) {
      ensureStyle();
      var root = document.querySelector('.page') || document.body;
      if (state.verticalRoot && state.verticalRoot !== root) {
        state.verticalRoot.classList.remove('intel-vertical-column');
      }
      document.documentElement.classList.add('intel-vertical');
      root.classList.add('intel-vertical-column');
      state.verticalRoot = root;
      document.documentElement.style.setProperty('--intel-column-width', metrics.width + 'px');
      document.documentElement.style.setProperty('--intel-column-top', metrics.marginY + 'px');
      document.documentElement.style.setProperty('--intel-page-height', metrics.height + 'px');
    };

    var removeVerticalFrame = function () {
      document.documentElement.classList.remove('intel-vertical');
      if (state.verticalRoot) {
        state.verticalRoot.classList.remove('intel-vertical-column');
        state.verticalRoot = null;
      }
      document.documentElement.style.removeProperty('--intel-column-width');
      document.documentElement.style.removeProperty('--intel-column-top');
      document.documentElement.style.removeProperty('--intel-page-height');
    };

    // Scroll mode is continuous, but it still shows the very same text
    // column as the two paged modes: same width, same centring, same top
    // inset. Only the vertical flow (and the lack of page steps) differs.
    var applyScrollFrame = function (metrics) {
      ensureStyle();
      var root = document.querySelector('.page') || document.body;
      if (state.scrollRoot && state.scrollRoot !== root) {
        state.scrollRoot.classList.remove('intel-scroll-column');
      }
      document.documentElement.classList.add('intel-scroll');
      root.classList.add('intel-scroll-column');
      state.scrollRoot = root;
      state.metrics = metrics;
      document.documentElement.style.setProperty('--intel-column-width', metrics.width + 'px');
      document.documentElement.style.setProperty('--intel-column-top', metrics.marginY + 'px');
      document.documentElement.style.setProperty(
        '--intel-column-bottom', Math.max(96, metrics.marginY * 2) + 'px'
      );
    };

    var removeScrollFrame = function () {
      document.documentElement.classList.remove('intel-scroll');
      if (state.scrollRoot) {
        state.scrollRoot.classList.remove('intel-scroll-column');
        state.scrollRoot = null;
      }
      document.documentElement.style.removeProperty('--intel-column-width');
      document.documentElement.style.removeProperty('--intel-column-top');
      document.documentElement.style.removeProperty('--intel-column-bottom');
    };

    var computeMetrics = function () {
      var viewportWidth = window.innerWidth;
      var viewportHeight = window.innerHeight;
      var width = Math.min(760, viewportWidth - 96);
      if (width < 280) { width = Math.max(200, viewportWidth - 48); }
      width = Math.round(width);
      var marginX = Math.round((viewportWidth - width) / 2);
      var marginY = Math.max(28, Math.min(56, Math.round(viewportHeight * 0.06)));
      var height = Math.max(200, viewportHeight - marginY * 2);
      return {
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        width: width,
        marginX: marginX,
        marginY: marginY,
        height: height,
        gap: viewportWidth - width,
        step: viewportWidth
      };
    };

    // The text column keeps its page metrics after the window widens
    // without changing the column itself (the sidebar sliding out), so
    // its live distance from the window edge is not metrics.marginX any
    // more. Caret probes and click bands must follow the visible margin.
    var visibleMarginX = function (metrics) {
      var frameWidth = Math.min(window.innerWidth, Math.max(1, metrics.viewportWidth));
      var frameLeft = Math.round((window.innerWidth - frameWidth) / 2);
      return Math.max(0, frameLeft + metrics.marginX);
    };

    // Keep the page window exactly one frozen page step wide. When the
    // text width and page height are unchanged there is nothing to
    // re-columnise: sliding this frame to the window centre puts the
    // text where a full relayout would, while its own clipping keeps
    // the next column hidden during the transition.
    var applyViewportFrame = function (metrics) {
      var viewport = ensureViewport();
      var windowWidth = window.innerWidth;
      var frameWidth = Math.min(windowWidth, Math.max(1, metrics.viewportWidth));
      viewport.style.left = Math.round((windowWidth - frameWidth) / 2) + 'px';
      viewport.style.width = frameWidth + 'px';
    };

    // Vertical page mode: the screen height rarely lines up with the text
    // grid, so stepping by a plain screen height slices the boundary line in
    // half. Build the pages from the real line boxes instead and always
    // start a page at the top of a line; whatever does not fit leaves a
    // small blank strip at the bottom of the previous page.
    var verticalPages = null;
    var verticalLineBoxes = null;
    var verticalFingerprint = null;
    var invalidateVerticalPages = function () {
      verticalPages = null;
      verticalLineBoxes = null;
      verticalFingerprint = null;
    };

    // WebKit can settle a late line-metric change (font fallback for a rare
    // glyph, a scrollbar, a lazy image) after the pages were measured. The
    // real line grid then sits a few pixels above the stored starts and the
    // boundary line gets sliced again. Content height is a cheap fingerprint
    // of that drift: when it moves, the pages are rebuilt from the current
    // line boxes before the next turn or mask update.
    var contentHeight = function () {
      var total = document.documentElement.scrollHeight;
      if (tailSpacer) {
        var spacerRect = tailSpacer.getBoundingClientRect();
        if (spacerRect.height > 0) { total -= spacerRect.height; }
      }
      return Math.round(total);
    };

    var layoutFingerprint = function () {
      // Only the text grid moves the line boxes. A window-width change
      // that leaves the fixed column untouched (sidebar toggle) must not
      // discard the vertical page starts and re-measure the book.
      var metrics = computeMetrics();
      return metrics.width + 'x' + metrics.height + '|' + contentHeight();
    };

    // Merge overlapping rectangles (a heading's inline boxes, a link that
    // spans several lines, an image next to a caption) into the real visual
    // line grid. Coordinates are relative to the passed origin.
    var mergeLineRects = function (raw) {
      raw.sort(function (a, b) { return a.top - b.top || a.bottom - b.bottom; });
      var lines = [];
      for (var j = 0; j < raw.length; j++) {
        var current = raw[j];
        var last = lines.length ? lines[lines.length - 1] : null;
        if (last && (current.top - last.top < 8 || current.top < last.bottom - 1)) {
          last.bottom = Math.max(last.bottom, current.bottom);
        } else {
          lines.push({ top: current.top, bottom: current.bottom });
        }
      }
      return lines;
    };

    var collectLineBoxes = function () {
      var root = document.querySelector('.page') || document.body;
      var raw = [];
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
      var node;
      while ((node = walker.nextNode())) {
        if (!(node.nodeValue || '').trim()) { continue; }
        var range = document.createRange();
        range.selectNodeContents(node);
        var rects = range.getClientRects();
        for (var i = 0; i < rects.length; i++) {
          var rect = rects[i];
          if (rect.width < 1 || rect.height < 1) { continue; }
          raw.push({
            top: rect.top + window.scrollY,
            bottom: rect.bottom + window.scrollY
          });
        }
      }
      var media = root.querySelectorAll('img, svg, video, canvas');
      for (var m = 0; m < media.length; m++) {
        var mediaRect = media[m].getBoundingClientRect();
        if (mediaRect.width < 1 || mediaRect.height < 1) { continue; }
        raw.push({
          top: mediaRect.top + window.scrollY,
          bottom: mediaRect.bottom + window.scrollY
        });
      }
      return mergeLineRects(raw);
    };

    // Horizontal columns and vertical pages must hold the same text. Both
    // modes use the same column width, so they break lines identically;
    // only the page boundaries drift because WebKit preserves a block's
    // top margin (and half-leading) at the top of a column while vertical
    // pages start at the bare line box. Record each column's line count
    // and that top offset, then place vertical page starts on the same
    // lines with the same offset.
    var collectColumnStats = function (root, metrics, originLeft, originTop, columnCount) {
      var columns = [];
      for (var c = 0; c < columnCount; c++) { columns.push([]); }
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
      var node;
      var pushRect = function (rect) {
        if (rect.width < 1 || rect.height < 1) { return; }
        var relativeLeft = rect.left - originLeft;
        var index = Math.floor((relativeLeft + 0.5) / metrics.step);
        if (index < 0) { index = 0; }
        if (index >= columnCount) { index = columnCount - 1; }
        columns[index].push({
          top: rect.top - originTop,
          bottom: rect.bottom - originTop
        });
      };
      while ((node = walker.nextNode())) {
        if (!(node.nodeValue || '').trim()) { continue; }
        var range = document.createRange();
        range.selectNodeContents(node);
        var rects = range.getClientRects();
        for (var i = 0; i < rects.length; i++) { pushRect(rects[i]); }
      }
      var media = root.querySelectorAll('img, svg, video, canvas');
      for (var m = 0; m < media.length; m++) {
        pushRect(media[m].getBoundingClientRect());
      }
      var stats = [];
      var total = 0;
      for (var k = 0; k < columnCount; k++) {
        var lines = mergeLineRects(columns[k]);
        var offset = lines.length ? lines[0].top : 0;
        stats.push({ count: lines.length, offset: Math.round(offset) });
        total += lines.length;
      }
      return { columns: stats, total: total };
    };

    // The cached stats describe the wrapper's own column grid: text
    // width, page height, and the step the columns advance on. The live
    // window width is only the frame around that grid, so it must not
    // invalidate a cache filled before a sidebar toggle - otherwise the
    // first probe after every widen would walk the whole book again.
    var statsKey = function (metrics) {
      // The column grid is described by its step and text size; the frame
      // around it (viewportWidth/marginX) may shrink without touching a
      // single column, so a sidebar toggle must not invalidate this cache.
      return metrics.step + '@' + metrics.width + 'x' + metrics.height;
    };
    var cachedColumnStats = null;

    var statsFromWrapper = function (metrics) {
      if (!state.wrapper || !document.body.contains(state.wrapper)) { return null; }
      var wrapperRect = state.wrapper.getBoundingClientRect();
      var stats = collectColumnStats(
        state.wrapper, metrics, wrapperRect.left, wrapperRect.top, Math.max(1, state.pages)
      );
      return stats.total > 0 ? stats : null;
    };

    // Vertical mode has no wrapper, so measure the columns by temporarily
    // laying the root out as the same multicol block. The reflow is
    // synchronous inside one task (nothing paints) and the scroll offset
    // is restored before returning.
    var statsInPlace = function (metrics) {
      var root = document.querySelector('.page') || document.body;
      if (!root) { return null; }
      var scrollX = window.scrollX;
      var scrollY = window.scrollY;
      var savedStyle = root.getAttribute('style') || '';
      var hadVerticalClass = root.classList.contains('intel-vertical-column');
      var hadHtmlClass = document.documentElement.classList.contains('intel-vertical');
      document.documentElement.classList.remove('intel-vertical');
      root.classList.remove('intel-vertical-column');
      var props = {
        'box-sizing': 'content-box',
        'width': metrics.width + 'px',
        'height': metrics.height + 'px',
        'max-width': 'none',
        'margin': '0',
        'padding': '0',
        'column-width': metrics.width + 'px',
        'column-gap': metrics.gap + 'px',
        'column-fill': 'auto'
      };
      for (var key in props) {
        root.style.setProperty(key, props[key], 'important');
      }
      var stats = null;
      try {
        void root.offsetWidth;
        var rootRect = root.getBoundingClientRect();
        var extent = root.scrollWidth;
        var columnCount = Math.max(1, Math.ceil((extent + metrics.gap - 0.5) / metrics.step));
        if (columnCount <= 8000) {
          stats = collectColumnStats(root, metrics, rootRect.left, rootRect.top, columnCount);
          if (!stats.total) { stats = null; }
        }
      } catch (e) {
        stats = null;
      }
      root.style.cssText = savedStyle;
      if (hadVerticalClass) { root.classList.add('intel-vertical-column'); }
      if (hadHtmlClass) { document.documentElement.classList.add('intel-vertical'); }
      window.scrollTo(scrollX, scrollY);
      if (stats) { stats.columnCount = stats.columns.length; }
      return stats;
    };

    var ensureColumnStats = function (metrics) {
      var key = statsKey(metrics);
      if (cachedColumnStats && cachedColumnStats.key === key) {
        return cachedColumnStats;
      }
      var stats = null;
      if (state.mode === 'horizontal' && state.wrapper) {
        stats = statsFromWrapper(metrics);
      }
      if (!stats) { stats = statsInPlace(metrics); }
      if (stats) {
        stats.key = key;
        cachedColumnStats = stats;
      }
      return stats;
    };

    var buildPagesFromColumns = function (stats, lines, metrics) {
      if (!stats || !stats.columns || !stats.columns.length) { return null; }
      if (!lines.length || stats.total !== lines.length) { return null; }
      var pages = [];
      var cumulative = 0;
      for (var k = 0; k < stats.columns.length; k++) {
        var column = stats.columns[k];
        var line = lines[cumulative];
        if (!column || column.count <= 0 || !line) { return null; }
        var start = Math.round(line.top - metrics.marginY - column.offset);
        if (start < 0) { start = 0; }
        if (pages.length && start <= pages[pages.length - 1].start) { return null; }
        pages.push({ start: start, offset: column.offset });
        cumulative += column.count;
      }
      if (cumulative !== lines.length) { return null; }
      return pages;
    };

    var lineScanPages = function (lines, metrics) {
      var pages = [];
      var lineIndex = 0;
      var guard = 0;
      while (lineIndex < lines.length && guard < 20000) {
        guard++;
        var first = lines[lineIndex];
        var limit = first.top + metrics.height;
        var scan = lineIndex + 1;
        while (scan < lines.length && lines[scan].top < limit - 0.5) {
          if (lines[scan].bottom > limit + 0.5) { break; }
          scan++;
        }
        pages.push({ start: Math.max(0, Math.round(first.top - metrics.marginY)), offset: 0 });
        if (scan <= lineIndex + 1) {
          // One line or image is taller than the page. Step a whole line
          // so paging still advances; the mask hides the overhang.
          scan = lineIndex + 1;
        }
        lineIndex = scan;
      }
      return pages;
    };

    // Give the final page enough scroll room to sit at the top of the
    // viewport. Without it the last page start would be past the maximum
    // scroll offset and the browser would clamp the page turn.
    var tailSpacer = null;
    var ensureTailSpacer = function () {
      if (tailSpacer && document.body.contains(tailSpacer)) { return tailSpacer; }
      tailSpacer = document.createElement('div');
      tailSpacer.id = 'intel-paged-tail';
      tailSpacer.setAttribute('data-intel-overlay', '1');
      tailSpacer.style.cssText =
        'display:block;height:0;margin:0;padding:0;border:0;flex:none;';
      document.body.appendChild(tailSpacer);
      return tailSpacer;
    };

    var removeTailSpacer = function () {
      if (tailSpacer && tailSpacer.parentNode) {
        tailSpacer.parentNode.removeChild(tailSpacer);
      }
      tailSpacer = null;
    };

    var syncVerticalTail = function (pages, viewportHeight) {
      var spacer = ensureTailSpacer();
      spacer.style.height = '0px';
      var lastStart = pages[pages.length - 1].start;
      // Keep a modest blank tail past the last page. A scrollbar that
      // disappears between paged modes can grow the viewport without a
      // resize event, and the slack keeps the last page reachable.
      var needed = lastStart + viewportHeight + 96;
      var extra = Math.ceil(needed - document.documentElement.scrollHeight);
      if (extra < 0) { extra = 0; }
      spacer.style.height = extra + 'px';
      for (var i = 0; i < 2; i++) {
        var shortfall = needed - document.documentElement.scrollHeight;
        if (shortfall <= 0) { break; }
        extra += Math.ceil(shortfall);
        spacer.style.height = extra + 'px';
      }
    };

    var ensureVerticalPages = function () {
      if (verticalPages) {
        if (layoutFingerprint() === verticalFingerprint) { return verticalPages; }
        // The line grid drifted after it was measured; the column grid
        // describes the old metrics too.
        invalidateVerticalPages();
        cachedColumnStats = null;
      }
      var metrics = computeMetrics();
      state.metrics = metrics;
      applyVerticalFrame(metrics);
      var viewportHeight = Math.max(200, window.innerHeight);
      // Prefer page starts derived from the horizontal columns: page k
      // then begins on the same line and with the same top offset as the
      // k-th horizontal page. Fall back to scanning the vertical line grid
      // when the two layouts disagree (a late font settle, an image).
      var stats = ensureColumnStats(metrics);
      var lines = collectLineBoxes();
      var pages = buildPagesFromColumns(stats, lines, metrics);
      if (!pages || !pages.length) {
        pages = lineScanPages(lines, metrics);
      }
      if (!pages.length) { pages = [{ start: 0, offset: 0 }]; }
      verticalPages = pages;
      verticalLineBoxes = lines;
      syncVerticalTail(pages, viewportHeight);
      verticalFingerprint = layoutFingerprint();
      return pages;
    };

    // A window scroll can stop anywhere, so the line that crosses the
    // viewport edge is still half rendered. Cover the partial strip with
    // the page background so only whole lines are ever visible.
    var masks = null;
    var ensureMasks = function () {
      if (masks && document.body.contains(masks.top)) { return masks; }
      var top = document.createElement('div');
      top.id = 'intel-vertical-mask-top';
      top.setAttribute('data-intel-overlay', '1');
      top.style.cssText =
        'position:fixed;left:0;right:0;top:0;height:0;pointer-events:none;z-index:2147483000;';
      var bottom = document.createElement('div');
      bottom.id = 'intel-vertical-mask-bottom';
      bottom.setAttribute('data-intel-overlay', '1');
      bottom.style.cssText =
        'position:fixed;left:0;right:0;bottom:0;height:0;pointer-events:none;z-index:2147483000;';
      document.body.appendChild(top);
      document.body.appendChild(bottom);
      masks = { top: top, bottom: bottom };
      return masks;
    };

    var removeMasks = function () {
      if (!masks) { return; }
      if (masks.top.parentNode) { masks.top.parentNode.removeChild(masks.top); }
      if (masks.bottom.parentNode) { masks.bottom.parentNode.removeChild(masks.bottom); }
      masks = null;
    };

    // Line boxes are sorted and their bottoms increase; find the first
    // one that reaches past `y` instead of walking the whole book on every
    // scroll frame.
    var firstLineBelow = function (lines, y) {
      var lo = 0;
      var hi = lines.length;
      while (lo < hi) {
        var mid = (lo + hi) >> 1;
        if (lines[mid].bottom <= y + 0.5) { lo = mid + 1; } else { hi = mid; }
      }
      return lo;
    };

    var updateVerticalMask = function () {
      if (state.mode !== 'vertical') {
        removeMasks();
        return;
      }
      var m = ensureMasks();
      var color = getComputedStyle(document.body).backgroundColor || '#ffffff';
      m.top.style.background = color;
      m.bottom.style.background = color;
      var lines = verticalLineBoxes || [];
      var metrics = state.metrics || computeMetrics();
      var band = Math.max(0, metrics.marginY);
      var topY = window.scrollY;
      var viewportBottom = topY + window.innerHeight;
      var topLimit = topY + band;
      var bottomLimit = viewportBottom - band;
      var topHeight = band;
      var bottomHeight = band;
      var topIndex = firstLineBelow(lines, topLimit);
      if (topIndex < lines.length) {
        var line = lines[topIndex];
        if (line.top < topLimit - 0.5) { topHeight = line.bottom - topY; }
      }
      var bottomIndex = firstLineBelow(lines, bottomLimit);
      if (bottomIndex < lines.length) {
        var next = lines[bottomIndex];
        if (next.top < viewportBottom - 0.5 && next.top < bottomLimit - 0.5) {
          // Cover from the straddling line's top down to the viewport
          // bottom. Height is viewport-relative; line boxes are in
          // document coordinates.
          bottomHeight = window.innerHeight - (next.top - topY);
        }
      }
      m.top.style.height = Math.max(0, Math.round(Math.min(topHeight, window.innerHeight))) + 'px';
      m.bottom.style.height = Math.max(0, Math.round(Math.min(bottomHeight, window.innerHeight))) + 'px';
    };

    var verticalPageIndexAt = function (scrollTop) {
      var pages = ensureVerticalPages();
      var lo = 0;
      var hi = pages.length - 1;
      var best = 0;
      while (lo <= hi) {
        var mid = (lo + hi) >> 1;
        if (pages[mid].start <= scrollTop + 1) {
          best = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      return best;
    };

    var verticalSnap = function (target) {
      var pages = ensureVerticalPages();
      return pages[verticalPageIndexAt(target)].start;
    };

    var positionInfo = function () {
      if (state.mode === 'scroll') { return null; }
      if (state.mode === 'horizontal') {
        return { page: state.page + 1, pages: state.pages };
      }
      var pages = ensureVerticalPages();
      updateVerticalMask();
      return { page: verticalPageIndexAt(window.scrollY) + 1, pages: pages.length };
    };

    var postIndicator = function () {
      if (state.silent) { return; }
      var info = positionInfo();
      if (!info) { return; }
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.readerPageInfo) {
        window.webkit.messageHandlers.readerPageInfo.postMessage(info);
      }
    };

    // Four fixed click bands over the blank page margins: left/right in
    // horizontal paging, top/bottom in vertical paging. A chevron fades in
    // under the cursor so the reserved space advertises what it does.
    var zones = null;
    var ensureTurnZones = function () {
      if (zones) { return zones; }
      var chevron = {
        left: '<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 18l-6-6 6-6"/></svg>',
        right: '<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18l6-6-6-6"/></svg>',
        up: '<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 15l-6-6-6 6"/></svg>',
        down: '<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>'
      };
      var make = function (dir) {
        var el = document.createElement('div');
        el.className = 'intel-turn-zone';
        el.setAttribute('data-intel-overlay', '1');
        el.style.cssText =
          'position:fixed;display:none;z-index:2147483002;align-items:center;justify-content:center;' +
          'cursor:pointer;-webkit-user-select:none;user-select:none;';
        var arrow = document.createElement('div');
        arrow.className = 'intel-turn-arrow';
        arrow.style.cssText =
          'opacity:0;transition:opacity 120ms ease-out;pointer-events:none;display:flex;';
        arrow.innerHTML = chevron[dir];
        el.appendChild(arrow);
        el.addEventListener('click', function (event) {
          if (event.metaKey || event.ctrlKey || event.altKey) { return; }
          var selection = window.getSelection();
          if (selection && selection.toString().length > 0) { return; }
          event.preventDefault();
          turn(dir === 'left' || dir === 'up' ? -1 : 1);
        });
        document.body.appendChild(el);
        return { el: el, arrow: arrow };
      };
      zones = {
        left: make('left'),
        right: make('right'),
        top: make('up'),
        bottom: make('down')
      };
      return zones;
    };

    var placeZone = function (zone, visible, box) {
      var style = zone.el.style;
      style.display = visible ? 'flex' : 'none';
      style.left = 'auto';
      style.right = 'auto';
      style.top = 'auto';
      style.bottom = 'auto';
      style.width = 'auto';
      style.height = 'auto';
      if (!visible) { return; }
      for (var key in box) { style[key] = box[key]; }
    };

    var updateTurnZones = function () {
      var z = ensureTurnZones();
      var horizontal = state.mode === 'horizontal';
      var vertical = state.mode === 'vertical';
      if (!horizontal && !vertical) {
        placeZone(z.left, false, null);
        placeZone(z.right, false, null);
        placeZone(z.top, false, null);
        placeZone(z.bottom, false, null);
        return;
      }
      var metrics = state.metrics || computeMetrics();
      var color = getComputedStyle(document.body).color || '#333333';
      if (!color || color === 'rgba(0, 0, 0, 0)') { color = '#333333'; }
      var all = [z.left, z.right, z.top, z.bottom];
      for (var i = 0; i < all.length; i++) { all[i].el.style.color = color; }
      // Keep the click bands to the blank margin itself, capped so a wide
      // window does not turn every side click into a page turn.
      var side = Math.max(32, Math.min(96, Math.round(visibleMarginX(metrics) * 0.75)));
      var band = Math.max(20, Math.round(metrics.marginY));
      placeZone(z.left, horizontal, { left: '0px', top: '0px', bottom: '0px', width: side + 'px' });
      placeZone(z.right, horizontal, { right: '0px', top: '0px', bottom: '0px', width: side + 'px' });
      placeZone(z.top, vertical, { left: '0px', right: '0px', top: '0px', height: band + 'px' });
      placeZone(z.bottom, vertical, { left: '0px', right: '0px', bottom: '0px', height: band + 'px' });
    };

    var setPage = function (index, animate) {
      var metrics = state.metrics;
      if (!metrics) { return; }
      state.page = Math.max(0, Math.min(index, state.pages - 1));
      var viewport = state.viewport;
      if (!viewport) { return; }
      var left = state.page * metrics.step;
      if (animate && viewport.scrollTo) {
        // Let WebKit scroll its own composited layer. Animating a
        // transform on the full-width column layer re-rasterised the
        // whole book on every turn and stuttered; a native scroller
        // only paints the visible page.
        viewport.scrollTo({ left: left, behavior: 'smooth' });
      } else {
        viewport.scrollLeft = left;
      }
      postIndicator();
    };

    var pageForRect = function (rect) {
      if (!rect || !state.wrapper || !state.metrics) { return 0; }
      var wrapperRect = state.wrapper.getBoundingClientRect();
      var offset = rect.left - wrapperRect.left;
      return Math.max(0, Math.min(state.pages - 1, Math.round(offset / state.metrics.step)));
    };

    var layout = function (preferredPage) {
      ensureStyle();
      removeScrollFrame();
      removeVerticalFrame();
      removeTailSpacer();
      removeMasks();
      var wrapper = ensureWrapper();
      var viewport = state.viewport;
      var metrics = computeMetrics();
      state.metrics = metrics;
      applyViewportFrame(metrics);
      // The wrapper margin provides the left gutter; the spacer below
      // provides the matching right gutter inside the scroller.
      viewport.style.paddingRight = '0px';
      wrapper.style.transition = 'none';
      wrapper.style.transform = 'none';
      wrapper.style.width = metrics.width + 'px';
      wrapper.style.height = metrics.height + 'px';
      wrapper.style.marginLeft = metrics.marginX + 'px';
      wrapper.style.marginRight = '0';
      wrapper.style.marginTop = metrics.marginY + 'px';
      wrapper.style.marginBottom = '0';
      wrapper.style.padding = '0';
      wrapper.style.columnWidth = metrics.width + 'px';
      wrapper.style.columnGap = metrics.gap + 'px';
      wrapper.style.columnFill = 'auto';
      wrapper.style.setProperty('--intel-page-height', metrics.height + 'px');
      document.documentElement.classList.add('intel-paged');
      document.body.classList.add('intel-paged');
      window.scrollTo(0, 0);
      viewport.scrollLeft = 0;
      void wrapper.offsetWidth;
      var extent = wrapper.scrollWidth;
      state.pages = Math.max(1, Math.ceil((extent + metrics.gap - 0.5) / metrics.step));
      var spacer = ensureRightSpacer(viewport);
      spacer.style.left =
        (metrics.marginX + (state.pages - 1) * metrics.step + metrics.width) + 'px';
      spacer.style.width = metrics.marginX + 'px';
      // A page handed over from the vertical layout lets the first painted
      // frame already be the target page: scrolling to page 0 first and
      // fixing it one task later made the reader flash a different page
      // while a long TXT was re-columned.
      var initialPage = typeof preferredPage === 'number' ? preferredPage : state.page;
      state.page = Math.max(0, Math.min(initialPage, state.pages - 1));
      setPage(state.page, false);
      state.ready = true;
      updateTurnZones();
    };

    var teardown = function (preserveWrapper) {
      var wrapper = state.wrapper;
      if (wrapper) {
        if (preserveWrapper) {
          // Keep the whole book inside one stable wrapper. Moving tens of
          // thousands of nodes back to <body> on every mode change cost
          // ~650 ms on a 1 MB TXT; vertical paging reads `.page` either way.
          wrapper.style.cssText = '';
          wrapper.className = 'intel-paged-root';
          if (wrapper.parentNode !== document.body) {
            document.body.appendChild(wrapper);
          }
        } else {
          // Put the book back where it came from so the plain scroll mode
          // sees the untouched document structure.
          var children = Array.prototype.slice.call(wrapper.childNodes);
          for (var i = 0; i < children.length; i++) {
            document.body.appendChild(children[i]);
          }
          if (wrapper.parentNode) { wrapper.parentNode.removeChild(wrapper); }
          wrapper.style.cssText = '';
          state.wrapper = null;
        }
      }
      var viewport = state.viewport;
      if (viewport) {
        if (viewport.parentNode) { viewport.parentNode.removeChild(viewport); }
        state.viewport = null;
      }
      document.documentElement.classList.remove('intel-paged');
      document.body.classList.remove('intel-paged');
      removeRightSpacer();
      removeTailSpacer();
      removeMasks();
      invalidateVerticalPages();
      state.metrics = null;
      state.pages = 1;
      state.page = 0;
      updateTurnZones();
    };

    var progressFraction = function () {
      if (state.mode === 'horizontal') {
        return state.pages <= 1 ? 0 : state.page / (state.pages - 1);
      }
      var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
      return max <= 0 ? 0 : Math.min(1, Math.max(0, window.scrollY / max));
    };

    var scrollToFraction = function (fraction) {
      var clamped = Math.min(Math.max(fraction, 0), 1);
      if (state.mode === 'vertical') {
        // Build the page grid (which applies the shared column frame)
        // before measuring the sentence, otherwise the rectangle would
        // describe the un-framed document and land on a different line.
        ensureVerticalPages();
        var rect = textRectForFraction(clamped);
        var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
        var target = rect ? rect.top + window.scrollY : max * clamped;
        // Land on the top of the page that holds the sentence, never on
        // an arbitrary scroll offset that could cut the first line.
        window.scrollTo(0, Math.max(0, verticalSnap(target)));
        return rect !== null;
      }
      var rect = textRectForFraction(clamped);
      var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
      // Scroll mode now starts its text at the same inset as the paged
      // modes, so returning to the same sentence keeps the same top gap.
      var inset = state.mode === 'scroll' && state.metrics ? state.metrics.marginY : 12;
      var top = rect ? rect.top + window.scrollY - inset : max * clamped;
      window.scrollTo(0, Math.max(0, top));
      return rect !== null;
    };

    var pageForFraction = function (fraction) {
      var rect = textRectForFraction(fraction);
      if (rect) { return pageForRect(rect); }
      return Math.round(Math.min(Math.max(fraction, 0), 1) * Math.max(0, state.pages - 1));
    };

    var scheduleReport = function (delay) {
      clearTimeout(state.reportTimer);
      state.reportTimer = setTimeout(function () {
        var report = window.__intelReaderPostPosition;
        if (report) { report(true); }
      }, delay);
    };

    var capturePosition = function () {
      var textFraction = textFractionAtTop();
      if (textFraction === null) { textFraction = state.lastTextFraction; }
      return { textFraction: textFraction, progress: progressFraction() };
    };

    var isPlainTextDocument = function () {
      return !!document.querySelector('.page.txt');
    };

    var restorePosition = function (position, usePage) {
      if (!position) { return; }
      var hasFraction = typeof position.textFraction === 'number';
      var hasPage = usePage && typeof position.page === 'number';
      var plainText = isPlainTextDocument();
      if (state.mode === 'horizontal') {
        state.silent = true;
        // TXT pages are built on the same line grid as the horizontal
        // columns, so its page number can be handed over directly and the
        // first painted frame is the target page. Other formats can use a
        // different page grid (DOCX page 9 started 13 paragraphs apart),
        // so they restore by the sentence at the top of the old page.
        if (hasPage && plainText) {
          layout(position.page);
          if (typeof position.pages === 'number' && state.pages !== position.pages && hasFraction) {
            setPage(pageForFraction(position.textFraction), false);
          }
        } else {
          layout();
          if (hasFraction) {
            setPage(pageForFraction(position.textFraction), false);
          } else {
            setPage(Math.round(Math.min(Math.max(position.progress || 0, 0), 1) * Math.max(0, state.pages - 1)), false);
          }
        }
        state.silent = false;
      } else if (state.mode === 'vertical') {
        var pages = ensureVerticalPages();
        if (hasPage && plainText && typeof position.pages === 'number' &&
            pages.length === position.pages && position.page < pages.length) {
          window.scrollTo(0, pages[position.page].start);
        } else {
          scrollToFraction(hasFraction ? position.textFraction : (position.progress || 0));
        }
      } else {
        // Apply the shared column before measuring, otherwise the scroll
        // offset would be computed for the publisher's narrower page.
        applyScrollFrame(computeMetrics());
        if (hasFraction) {
          scrollToFraction(position.textFraction);
        } else {
          var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
          window.scrollTo(0, max * Math.min(Math.max(position.progress || 0, 0), 1));
        }
      }
      if (hasFraction) { state.lastTextFraction = position.textFraction; }
      postIndicator();
    };

    var turn = function (delta) {
      if (state.mode === 'horizontal') {
        if (state.pages <= 1) { return; }
        var next = Math.min(state.pages - 1, Math.max(0, state.page + delta));
        if (next === state.page) { return; }
        setPage(next, true);
        scheduleReport(420);
        return;
      }
      if (state.mode === 'vertical') {
        var pages = ensureVerticalPages();
        var current = verticalPageIndexAt(window.scrollY);
        var next = current + delta;
        if (delta < 0 && window.scrollY > pages[current].start + 4) {
          // Part-way into a page: step back to its first line before
          // moving to the previous page.
          next = current;
        }
        next = Math.min(pages.length - 1, Math.max(0, next));
        var target = pages[next].start;
        if (Math.abs(target - window.scrollY) < 1) { return; }
        window.scrollTo({ top: target, behavior: 'smooth' });
        scheduleReport(420);
      }
    };

    var onWheel = function (event) {
      if (state.mode === 'scroll' || event.ctrlKey || event.metaKey) { return; }
      if (window.__intelReaderHold) { event.preventDefault(); return; }
      var delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY;
      if (Math.abs(delta) < 16) { return; }
      event.preventDefault();
      var now = Date.now();
      if (now - state.wheelAt < 420) { return; }
      state.wheelAt = now;
      turn(delta > 0 ? 1 : -1);
    };

    // Re-check the page grid once the layout has settled. Switching modes,
    // resizing, or a late font/style change can move the line grid after the
    // first measurement; without this the first screen could keep a sliced
    // boundary line until the next turn.
    var scheduleVerticalRecheck = function (delay) {
      clearTimeout(state.verticalRecheckTimer);
      state.verticalRecheckTimer = setTimeout(function () {
        if (state.mode !== 'vertical') { return; }
        var before = verticalPages;
        var pages = ensureVerticalPages();
        updateVerticalMask();
        if (pages !== before) {
          var current = pages[verticalPageIndexAt(window.scrollY)].start;
          var drift = Math.abs(current - window.scrollY);
          if (drift > 0.5 && drift <= Math.max(64, window.innerHeight * 0.25)) {
            window.scrollTo(0, current);
          }
          postIndicator();
          scheduleReport(360);
        }
      }, delay);
    };

    var onResize = function () {
      clearTimeout(state.resizeTimer);
      // The text column is fixed at 760 px and the page height depends
      // only on the window height, so most window-width changes (a
      // sidebar sliding in or out, a wider desktop) leave the column
      // grid untouched. Slide the frozen page frame to the new centre
      // right inside the resize event: nothing is re-columnised, page
      // numbers stay put, and the next column can never peek through
      // while a debounced relayout is pending.
      var live = computeMetrics();
      if (state.ready && state.metrics &&
          live.width === state.metrics.width && live.height === state.metrics.height) {
        if (state.mode === 'horizontal') {
          if (window.innerWidth < state.metrics.viewportWidth) {
            // The sidebar slid in and the window is now narrower than the
            // frozen page step. The column grid itself did not change, so
            // shrink only the visible frame and re-centre the text inside
            // it. Re-columnising here cost a full WebKit reflow and made
            // wrapper.scrollWidth keep its old value, which in turn
            // invented phantom trailing pages. Page numbers (one per
            // column) stay valid; the turns still step over the full grid.
            var frameMargin = live.marginX;
            state.metrics.viewportWidth = live.viewportWidth;
            state.metrics.marginX = frameMargin;
            if (state.wrapper) {
              state.wrapper.style.marginLeft = frameMargin + 'px';
            }
            if (rightSpacer) {
              rightSpacer.style.left =
                (frameMargin + (state.pages - 1) * state.metrics.step + state.metrics.width) + 'px';
              rightSpacer.style.width = frameMargin + 'px';
            }
          }
          applyViewportFrame(state.metrics);
          updateTurnZones();
          return;
        } else {
          if (state.mode === 'vertical') { updateVerticalMask(); }
          updateTurnZones();
          return;
        }
      }
      state.resizeTimer = setTimeout(function () {
        window.__intelReaderHold = true;
        // The resize event arrives after WebKit has already rewrapped the
        // text, so measuring the fraction here would describe the new
        // layout instead of the spot the reader was looking at. The last
        // reported fraction was captured in the old layout and is stable
        // across the reflow.
        var savedFraction = state.lastTextFraction;
        if (typeof savedFraction !== 'number') {
          savedFraction = capturePosition().textFraction;
        }
        if (state.mode === 'scroll') {
          // The shared column is derived from the viewport width, so a
          // narrow window re-applies it and lands on the same sentence.
          applyScrollFrame(computeMetrics());
          if (typeof savedFraction === 'number') {
            scrollToFraction(savedFraction);
          }
          setTimeout(function () {
            window.__intelReaderHold = false;
          }, 260);
          return;
        }
        invalidateVerticalPages();
        if (state.mode === 'horizontal') {
          state.silent = true;
          layout();
        }
        restorePosition({ textFraction: savedFraction });
        updateTurnZones();
        scheduleVerticalRecheck(360);
        setTimeout(function () {
          window.__intelReaderHold = false;
        }, 260);
      }, 180);
    };

    var enableInteractions = function () {
      if (state.interactions) { return; }
      state.interactions = true;
      window.addEventListener('wheel', onWheel, { passive: false });
      window.addEventListener('resize', onResize);
    };

    P.prepare = function () {
      state.silent = true;
      if (state.mode === 'horizontal') {
        layout();
      } else if (state.mode === 'vertical') {
        // Apply the shared page frame before anything measures text, so
        // the first anchor lookup happens in the final column width.
        ensureVerticalPages();
      } else {
        // Continuous scroll shares the paged column, so the first anchor
        // lookup already measures the same lines the paged modes show.
        applyScrollFrame(computeMetrics());
      }
      state.silent = false;
      enableInteractions();
      updateTurnZones();
    };

    P.notifyIndicator = postIndicator;

    // A theme change only swaps colors, so it must not touch the column
    // layout: repainting the fixed masks and the page indicator is enough.
    // `afterStyleChange` still handles font-size changes, which do reflow.
    P.refreshTheme = function () {
      updateVerticalMask();
      postIndicator();
    };

    P.topPoint = function () {
      var points = P.topPoints();
      return points.length ? points[0] : null;
    };

    // Candidate caret probes just inside the first line of the current
    // page. Horizontal pages keep the block's top offset inside their
    // column; vertical pages carry the same offset so the first line sits
    // at the same height in both modes.
    P.topPoints = function () {
      var points = [];
      if (state.mode === 'horizontal' && state.metrics) {
        var metrics = state.metrics;
        var offset = 0;
        var stats = ensureColumnStats(metrics);
        if (stats && stats.columns[state.page]) {
          offset = stats.columns[state.page].offset || 0;
        }
        var y = metrics.marginY + Math.max(6, offset) + 10;
        if (y > window.innerHeight - 8) { y = window.innerHeight - 8; }
        if (y < 2) { y = 2; }
        var marginX = visibleMarginX(metrics);
        var xs = [
          marginX + 12,
          marginX + Math.round(metrics.width * 0.35),
          marginX + Math.round(metrics.width * 0.6)
        ];
        for (var i = 0; i < xs.length; i++) {
          points.push({ x: Math.min(window.innerWidth - 8, Math.max(8, xs[i])), y: y });
        }
        return points;
      }
      if (state.mode === 'vertical') {
        var metricsV = state.metrics || computeMetrics();
        var pages = ensureVerticalPages();
        var index = verticalPageIndexAt(window.scrollY);
        var page = pages[index] || { start: 0, offset: 0 };
        var root = document.querySelector('.page') || document.body;
        var rootRect = root.getBoundingClientRect();
        var yV = metricsV.marginY + Math.max(6, page.offset || 0) + 10 +
          (page.start - window.scrollY);
        if (yV > window.innerHeight - 8) { yV = window.innerHeight - 8; }
        if (yV < 2) { yV = 2; }
        var left = rootRect.left;
        var xsV = [
          left + 12,
          left + Math.round(metricsV.width * 0.35),
          left + Math.round(metricsV.width * 0.6)
        ];
        for (var j = 0; j < xsV.length; j++) {
          points.push({ x: Math.min(window.innerWidth - 8, Math.max(8, xsV[j])), y: yV });
        }
        return points;
      }
      return points;
    };

    P.isColumnPaged = function () { return state.mode === 'horizontal'; };
    P.isPaged = function () { return state.mode !== 'scroll'; };
    P.snapVertical = function (top) {
      if (state.mode !== 'vertical') { return top; }
      return verticalSnap(Math.max(0, top));
    };
    P.pageCount = function () { return state.pages; };
    P.currentPage = function () { return state.page; };
    P.progressFraction = progressFraction;
    P.positionInfo = positionInfo;
    P.capturePosition = capturePosition;
    P.noteTextFraction = function (fraction) {
      if (typeof fraction === 'number') { state.lastTextFraction = fraction; }
    };
    P.goToPage = function (index, animate) {
      if (state.mode !== 'horizontal') { return; }
      setPage(index, animate === true);
    };
    P.goToPageFraction = function (fraction) {
      if (state.mode !== 'horizontal') { return; }
      setPage(pageForFraction(fraction), false);
    };
    P.goToRect = function (rect) {
      if (state.mode !== 'horizontal') { return; }
      setPage(pageForRect(rect), false);
    };
    P.turn = turn;

    P.setMode = function (mode) {
      if (mode !== 'scroll' && mode !== 'horizontal' && mode !== 'vertical') { return; }
      if (mode === state.mode) { return; }
      window.__intelReaderHold = true;
      var position = capturePosition();
      // Remember the page we are leaving as well as the sentence. Switching
      // between the two paged modes then lands on the same page directly.
      if (state.mode === 'horizontal') {
        position.page = state.page;
        position.pages = state.pages;
      } else if (state.mode === 'vertical') {
        position.page = verticalPageIndexAt(window.scrollY);
        position.pages = verticalPages ? verticalPages.length : null;
      }
      // Keep the horizontal column grid: the vertical pages are placed on
      // the same lines, and measuring it later without the wrapper would
      // cost an extra temporary reflow.
      if (state.mode === 'horizontal' && state.metrics) {
        ensureColumnStats(state.metrics);
      }
      state.mode = mode;
      invalidateVerticalPages();
      if (mode === 'vertical') {
        // Rebuild the vertical page grid from the same in-place measurement
        // as the first entry. Reusing the horizontal wrapper's column stats
        // here made FB2/DOCX page counts and page starts drift after a
        // round-trip (18 → 17 pages, a two-paragraph jump).
        cachedColumnStats = null;
      }
      if (mode !== 'horizontal') {
        teardown(mode === 'vertical');
        removeVerticalFrame();
        removeScrollFrame();
        // Let the column wrapper's overflow clear before line boxes and
        // the viewport height are measured for vertical pages.
        void document.documentElement.offsetHeight;
      } else {
        removeVerticalFrame();
        removeScrollFrame();
        removeMasks();
        removeTailSpacer();
      }
      restorePosition(position, true);
      updateTurnZones();
      setTimeout(function () {
        window.__intelReaderHold = false;
      }, 120);
      scheduleReport(320);
      scheduleVerticalRecheck(360);
    };

    P.ensureVerticalLayout = function () {
      if (state.mode !== 'vertical') { return; }
      ensureVerticalPages();
    };

    P.afterStyleChange = function (position) {
      window.__intelReaderHold = true;
      invalidateVerticalPages();
      cachedColumnStats = null;
      if (state.mode === 'horizontal' || state.mode === 'vertical') {
        restorePosition(position || { textFraction: state.lastTextFraction });
      } else if (position && typeof position.textFraction === 'number') {
        scrollToFraction(position.textFraction);
      }
      updateTurnZones();
      setTimeout(function () {
        window.__intelReaderHold = false;
      }, 260);
      scheduleVerticalRecheck(360);
    };

    P.setLastTextFraction = function (fraction) {
      P.noteTextFraction(fraction);
    };

    return P;
  })();

  var goToRect = function (rect) {
    if (!rect) { return false; }
    if (readerPager && readerPager.isColumnPaged()) {
      readerPager.goToRect(rect);
      return true;
    }
    var top = Math.max(0, rect.top + window.scrollY - 12);
    if (readerPager && readerPager.isPaged()) {
      // Vertical page mode: land on the page start that holds the line.
      top = readerPager.snapVertical(rect.top + window.scrollY);
    }
    window.scrollTo(0, top);
    return true;
  };

  var goToTextFraction = function (fraction) {
    if (readerPager && readerPager.isPaged() && !readerPager.isColumnPaged()) {
      readerPager.ensureVerticalLayout();
    }
    var rect = textRectForFraction(fraction);
    if (rect) {
      goToRect(rect);
      return true;
    }
    if (readerPager && readerPager.isColumnPaged()) {
      readerPager.goToPageFraction(fraction);
      return false;
    }
    var currentMax = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    var top = currentMax * fraction;
    if (readerPager && readerPager.isPaged()) {
      top = readerPager.snapVertical(top);
    }
    window.scrollTo(0, top);
    return false;
  };

  // The native reader keeps an opaque overlay above the WebView until the
  // saved position is on screen; this tells it the page can be revealed.
  var postReady = function () {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.readerReady) {
      window.webkit.messageHandlers.readerReady.postMessage({});
    }
  };

  var postAnchored = function () {
    var fraction = readerPager
      ? readerPager.progressFraction()
      : (function () {
          var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
          return max <= 0 ? 0 : window.scrollY / max;
        })();
    var textFraction = textFractionAtTop();
    var payload = {
      progress: fraction,
      text: topSnippet() || initialNeedle,
      anchored: true
    };
    if (textFraction !== null) { payload.textProgress = textFraction; }
    if (readerPager) {
      readerPager.noteTextFraction(textFraction);
      var info = readerPager.positionInfo();
      if (info) {
        payload.page = info.page;
        payload.pages = info.pages;
      }
    }
    window.webkit.messageHandlers.readerProgress.postMessage(payload);
    window.__intelReaderHold = false;
    postReady();
  };

  var postPosition = function (settled) {
    var fraction = readerPager
      ? readerPager.progressFraction()
      : (function () {
          var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
          return max <= 0 ? 0 : window.scrollY / max;
        })();
    var textFraction = textFractionAtTop();
    var payload = {
      progress: fraction,
      text: topSnippet(),
      anchored: false,
      settled: settled
    };
    if (textFraction !== null) { payload.textProgress = textFraction; }
    if (readerPager) {
      readerPager.noteTextFraction(textFraction);
      var info = readerPager.positionInfo();
      if (info) {
        payload.page = info.page;
        payload.pages = info.pages;
      }
    }
    window.webkit.messageHandlers.readerProgress.postMessage(payload);
  };

  window.__intelReaderPostPosition = postPosition;

  window.__intelReaderGoTo = function (needle, expected, textFraction) {
    window.__intelReaderHold = true;
    if (readerPager && readerPager.isPaged() && !readerPager.isColumnPaged()) {
      readerPager.ensureVerticalLayout();
    }
    var columnPaged = readerPager && readerPager.isColumnPaged();
    var anchorExpected = (columnPaged && typeof textFraction === 'number') ? textFraction : expected;
    var rect = needle ? anchorRect(needle, anchorExpected) : null;
    if (rect === null && typeof textFraction === 'number') {
      rect = textRectForFraction(textFraction);
    }
    if (rect !== null) {
      goToRect(rect);
    } else if (columnPaged) {
      readerPager.goToPageFraction(expected);
    } else {
      var currentMax = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
      var top = currentMax * expected;
      if (readerPager && readerPager.isPaged()) {
        top = readerPager.snapVertical(top);
      }
      window.scrollTo(0, top);
    }
    // External jumps suppress the scroll handler while __intelReaderHold is
    // set; refresh the page indicator explicitly, including after the hold.
    if (readerPager) { readerPager.notifyIndicator(); }
    setTimeout(function () {
      window.__intelReaderHold = false;
      if (readerPager) { readerPager.notifyIndicator(); }
    }, 300);
    return rect !== null;
  };

  window.__intelReaderSetMode = function (mode) {
    if (readerPager) { readerPager.setMode(mode); }
  };

  window.__intelReaderTurnPage = function (delta) {
    if (readerPager) { readerPager.turn(delta); }
  };

  window.__intelReaderPager = readerPager;

  var apply = function () {
    window.__intelReaderHold = true;
    if (readerPager) { readerPager.prepare(); }
    var currentMax = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    var expectedFraction = fallbackProgress;
    if (readerPager && readerPager.isColumnPaged() && initialTextFraction !== null) {
      expectedFraction = initialTextFraction;
    }
    var rect = hasAnchor ? anchorRect(initialNeedle, expectedFraction) : null;
    if (rect === null && initialTextFraction !== null) {
      rect = textRectForFraction(initialTextFraction);
    }
    if (rect !== null) {
      goToRect(rect);
    } else if (readerPager && readerPager.isColumnPaged()) {
      readerPager.goToPageFraction(fallbackProgress);
    } else {
      var applyTop = currentMax * fallbackProgress;
      if (readerPager && readerPager.isPaged()) {
        applyTop = readerPager.snapVertical(applyTop);
      }
      window.scrollTo(0, applyTop);
    }
    if (readerPager) { readerPager.notifyIndicator(); }
    if (!window.__intelReaderProgressInstalled) {
      window.__intelReaderProgressInstalled = true;
      window.addEventListener('scroll', function () {
        if (window.__intelReaderHold) { return; }
        postPosition(false);
        // Once the scroll comes to rest, report the exact resting
        // sentence even when it moved less than one percent.
        clearTimeout(window.__intelReaderSettleTimer);
        window.__intelReaderSettleTimer = setTimeout(function () {
          if (window.__intelReaderHold) { return; }
          postPosition(true);
        }, 300);
      }, { passive: true });
    }
    if (rect !== null) {
      setTimeout(postAnchored, 120);
    } else {
      setTimeout(function () {
        window.__intelReaderHold = false;
        postReady();
      }, 250);
    }
  };

  requestAnimationFrame(function () {
    requestAnimationFrame(apply);
  });
})();

"""#
    }
}
