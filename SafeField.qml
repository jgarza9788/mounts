import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Single-line text field with no Qt text-input item behind it.
//
// Why: Qt's TextInput / TextField (Qt 6.12.0 builds without upstream fix
// bcbfae6761016974d9185cecee333b5f7aaf0442) read offered Wayland clipboard
// text on their own (canPaste) with no size or time limit, so a hostile
// clipboard owner can stall or exhaust the shared shell. This field never
// touches the Qt clipboard: it builds its text from key events, and paste
// (Ctrl+V / Shift+Insert) runs `wl-paste` out of process with a timeout and
// a byte cap (SafeFieldClip.qml).
//
// Drop-in for the subset of the Omarchy TextField API plugins use: text,
// placeholderText, foreground / accent, password, maximumLength, readOnly,
// validator (int range or regular expression), inputMethodHints
// (Qt.ImhDigitsOnly), font, accepted / editingFinished / textEdited,
// selectAll / clear. Keys handlers set on an instance see every key first;
// whatever they leave unaccepted is typed here. Trade-off: no input-method
// (IME) composition.
Item {
  id: root

  property string text: ""
  property string placeholderText: ""
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color selectionTint: Style.selectionFillFor(foreground, accent)
  property color color: foreground
  property color placeholderTextColor: Qt.darker(foreground, 1.6)
  property bool password: false
  property bool readOnly: false
  property int maximumLength: 32767
  property var validator: null
  property int inputMethodHints: 0
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY
  property bool hasCursor: false
  property alias font: label.font
  // Upper bound for one paste, in bytes, before it is cut to maximumLength.
  property int pasteByteLimit: Math.min(65536, Math.max(256, maximumLength * 4))

  readonly property bool hovered: hover.hovered
  readonly property int length: text.length
  property int cursorPosition: 0
  property int _anchor: 0
  readonly property int selectionStart: Math.min(_anchor, cursorPosition)
  readonly property int selectionEnd: Math.max(_anchor, cursorPosition)
  readonly property string selectedText: text.substring(selectionStart, selectionEnd)
  readonly property string displayText: password ? "•".repeat(text.length) : text
  readonly property bool acceptableInput: _acceptable(text)

  signal accepted()
  signal editingFinished()
  signal textEdited()

  readonly property bool _focused: activeFocus
  readonly property bool _hot: hovered || hasCursor
  readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"), root.foreground, root.accent)
  readonly property real _left: horizontalPadding + Border.left(_borderSpec)
  readonly property real _right: horizontalPadding + Border.right(_borderSpec)
  property real _scroll: 0
  property var _paste: null

  activeFocusOnTab: true
  implicitWidth: Style.space(160)
  implicitHeight: Math.ceil(metrics.height) + 2 * verticalPadding + Border.top(_borderSpec) + Border.bottom(_borderSpec)
  clip: true

  onTextChanged: {
    if (cursorPosition > text.length) cursorPosition = text.length
    if (_anchor > text.length) _anchor = text.length
  }
  onActiveFocusChanged: {
    if (activeFocus) blink.restart()
    else { _anchor = cursorPosition; editingFinished() }
  }

  // Writes `text` without removing a binding the caller put on it, the way
  // Qt's own text fields do: the binding stays and wins when it re-evaluates.
  PropertyAction { id: writer; target: root; property: "text" }

  function _setText(value, edited) {
    if (value.length > maximumLength) value = value.substring(0, maximumLength)
    if (value === text) return false
    writer.value = value
    writer.start()
    if (edited) textEdited()
    return true
  }

  function _intRange() {
    return validator && validator.bottom !== undefined && validator.top !== undefined
  }
  function _digitsOnly() {
    return (inputMethodHints & Qt.ImhDigitsOnly) !== 0 || _intRange()
  }
  function _acceptable(value) {
    if (!validator) return true
    if (_intRange()) {
      if (!/^-?\d+$/.test(value)) return false
      const n = parseInt(value, 10)
      return n >= validator.bottom && n <= validator.top
    }
    if (validator.regularExpression !== undefined) {
      const re = new RegExp("^(?:" + validator.regularExpression.source + ")$")
      return re.test(value)
    }
    return true
  }
  // Only printable characters on one line; digits only when asked.
  function _clean(s) {
    s = String(s).replace(/[\r\n\t]+/g, " ").replace(/[\u0000-\u001f\u007f]/g, "")
    if (_digitsOnly()) s = s.replace(_intRange() && validator.bottom < 0 ? /[^\d-]/g : /\D/g, "")
    return s
  }

  function insert(position, s) {
    if (readOnly) return
    s = _clean(s)
    if (s === "") return
    const room = maximumLength - text.length
    if (room <= 0) return
    s = s.substring(0, room)
    position = Math.max(0, Math.min(position, text.length))
    if (_setText(text.substring(0, position) + s + text.substring(position), true)) {
      cursorPosition = position + s.length
      _anchor = cursorPosition
    }
  }
  function remove(start, end) {
    if (readOnly) return
    const a = Math.max(0, Math.min(start, end)), b = Math.min(text.length, Math.max(start, end))
    if (a === b) return
    if (_setText(text.substring(0, a) + text.substring(b), true)) {
      cursorPosition = a
      _anchor = a
    }
  }
  function _replaceSelection(s) {
    const a = selectionStart, b = selectionEnd
    if (a !== b) remove(a, b)
    insert(a, s)
  }
  function selectAll() { _anchor = 0; cursorPosition = text.length }
  function deselect() { _anchor = cursorPosition }
  function select(start, end) {
    _anchor = Math.max(0, Math.min(start, text.length))
    cursorPosition = Math.max(0, Math.min(end, text.length))
  }
  function clear() {
    if (_setText("", false)) { cursorPosition = 0; _anchor = 0 }
  }
  function copy() {
    if (password || selectedText === "") return
    _clip("copy", selectedText)
  }
  function cut() {
    if (password || readOnly || selectedText === "") return
    copy()
    remove(selectionStart, selectionEnd)
  }
  function paste() {
    if (readOnly || _paste) return
    _paste = _clip("paste", "")
  }
  // Runs one SafeFieldClip transfer; a paste lands where the cursor is then.
  function _clip(mode, payload) {
    const c = Qt.createComponent("SafeFieldClip.qml")
    if (c.status !== Component.Ready) return null
    const job = c.createObject(root, { mode: mode, payload: payload, byteLimit: pasteByteLimit })
    if (!job) return null
    job.done.connect(function (s) {
      if (mode === "paste") {
        root._paste = null
        if (s !== "") root._replaceSelection(s)
      }
      job.destroy()
    })
    job.start()
    return job
  }

  function _wordLeft(pos) {
    let i = pos
    while (i > 0 && /\s/.test(text[i - 1])) i--
    while (i > 0 && !/\s/.test(text[i - 1])) i--
    return i
  }
  function _wordRight(pos) {
    let i = pos
    while (i < text.length && /\s/.test(text[i])) i++
    while (i < text.length && !/\s/.test(text[i])) i++
    return i
  }
  function _move(pos, extend) {
    cursorPosition = Math.max(0, Math.min(pos, text.length))
    if (!extend) _anchor = cursorPosition
    blink.restart()
  }

  // Runs after every Keys handler set on the instance (see the order test).
  Connections {
    target: root.Keys
    function onPressed(e) {
      if (e.accepted) return
      const ctrl = (e.modifiers & Qt.ControlModifier) !== 0
      const shift = (e.modifiers & Qt.ShiftModifier) !== 0
      const word = ctrl && !root.password
      // Alt and Super chords are shortcuts, never text.
      if (e.modifiers & (Qt.AltModifier | Qt.MetaModifier)) return
      switch (e.key) {
      case Qt.Key_Return:
      case Qt.Key_Enter:
        if (root.acceptableInput) { root.accepted(); root.editingFinished() }  // Qt order
        e.accepted = true
        return
      case Qt.Key_Left:
        if (!shift && root.selectionStart !== root.selectionEnd) root._move(root.selectionStart, false)
        else root._move(word ? root._wordLeft(root.cursorPosition) : root.cursorPosition - 1, shift)
        e.accepted = true
        return
      case Qt.Key_Right:
        if (!shift && root.selectionStart !== root.selectionEnd) root._move(root.selectionEnd, false)
        else root._move(word ? root._wordRight(root.cursorPosition) : root.cursorPosition + 1, shift)
        e.accepted = true
        return
      case Qt.Key_Home:
        root._move(0, shift); e.accepted = true; return
      case Qt.Key_End:
        root._move(root.text.length, shift); e.accepted = true; return
      case Qt.Key_Backspace:
        if (root.selectionStart !== root.selectionEnd) root.remove(root.selectionStart, root.selectionEnd)
        else root.remove(word ? root._wordLeft(root.cursorPosition) : root.cursorPosition - 1, root.cursorPosition)
        e.accepted = true
        return
      case Qt.Key_Delete:
        if (shift && !ctrl) { root.cut(); e.accepted = true; return }
        if (root.selectionStart !== root.selectionEnd) root.remove(root.selectionStart, root.selectionEnd)
        else root.remove(root.cursorPosition, word ? root._wordRight(root.cursorPosition) : root.cursorPosition + 1)
        e.accepted = true
        return
      case Qt.Key_Insert:
        if (shift && !ctrl) { root.paste(); e.accepted = true }
        else if (ctrl && !shift) { root.copy(); e.accepted = true }
        return
      }
      if (ctrl) {
        switch (e.key) {
        case Qt.Key_A: root.selectAll(); e.accepted = true; return
        case Qt.Key_C: root.copy(); e.accepted = true; return
        case Qt.Key_X: root.cut(); e.accepted = true; return
        case Qt.Key_V: root.paste(); e.accepted = true; return
        case Qt.Key_U: if (!root.readOnly) root.remove(0, root.cursorPosition); e.accepted = true; return
        }
        return
      }
      if (e.text.length > 0 && !/[\u0000-\u001f\u007f]/.test(e.text)) {
        if (!root.readOnly) root._replaceSelection(e.text)
        e.accepted = true
      }
    }
  }

  FontMetrics { id: metrics; font: label.font }
  TextMetrics { id: probe; font: label.font }

  function _xAt(pos) {
    probe.text = displayText.substring(0, pos)
    return probe.advanceWidth
  }
  function _posAt(x) {
    const t = displayText
    let lo = 0, hi = t.length
    while (lo < hi) {
      const mid = (lo + hi) >> 1
      if (_xAt(mid + 1) - (_xAt(mid + 1) - _xAt(mid)) / 2 < x) lo = mid + 1
      else hi = mid
    }
    return lo
  }

  readonly property real _viewWidth: Math.max(0, width - _left - _right)
  readonly property real _cursorX: { displayText; cursorPosition; return _xAt(cursorPosition) }
  on_CursorXChanged: _keepVisible()
  on_ViewWidthChanged: _keepVisible()
  function _keepVisible() {
    if (_cursorX - _scroll > _viewWidth - 1) _scroll = _cursorX - _viewWidth + 1
    else if (_cursorX < _scroll) _scroll = _cursorX
    if (_scroll < 0) _scroll = 0
  }

  BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(root._focused, root._hot, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }

  Item {
    id: view
    x: root._left
    width: root._viewWidth
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    clip: true

    Rectangle {
      visible: root.selectionStart !== root.selectionEnd
      x: { root.displayText; return root._xAt(root.selectionStart) - root._scroll }
      width: { root.displayText; return root._xAt(root.selectionEnd) - root._xAt(root.selectionStart) }
      height: metrics.height
      anchors.verticalCenter: parent.verticalCenter
      color: root.selectionTint
    }
    Text {
      id: label
      x: -root._scroll
      anchors.verticalCenter: parent.verticalCenter
      text: root.displayText
      textFormat: Text.PlainText
      color: root.color
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    Text {
      visible: root.text.length === 0
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      elide: Text.ElideRight
      text: root.placeholderText
      textFormat: Text.PlainText
      color: root.placeholderTextColor
      font: label.font
    }
    Rectangle {
      id: caret
      visible: root.activeFocus && !root.readOnly && blink.on
      x: root._cursorX - root._scroll
      width: 1
      height: metrics.height
      anchors.verticalCenter: parent.verticalCenter
      color: root.color
    }
  }

  Timer {
    id: blink
    property bool on: true
    interval: 530
    repeat: true
    running: root.activeFocus
    onRunningChanged: on = true
    onTriggered: on = !on
    function restart() { on = true; stop(); if (root.activeFocus) start() }
  }

  HoverHandler { id: hover; cursorShape: Qt.IBeamCursor }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton
    cursorShape: Qt.IBeamCursor
    function posFor(mx) { return root._posAt(mx - root._left + root._scroll) }
    onPressed: function (m) {
      root.forceActiveFocus()
      root._move(posFor(m.x), (m.modifiers & Qt.ShiftModifier) !== 0)
    }
    onPositionChanged: function (m) { if (pressed) root._move(posFor(m.x), true) }
    onDoubleClicked: root.selectAll()
  }
}
