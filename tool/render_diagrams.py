#!/usr/bin/env python3
"""Render the README's UML sequence diagrams to SVG (docs/diagrams/*.svg).

pub.dev does not render Mermaid, so the README embeds these SVGs. Edit the
DIAGRAMS below and run `python3 tool/render_diagrams.py`; no dependencies.
"""
import pathlib
from xml.sax.saxutils import escape

OUT = pathlib.Path(__file__).resolve().parents[1] / 'docs' / 'diagrams'

# Steps: ('call'|'reply', from, to, label), ('self', who, label),
# ('note', first, last, text), ('group', kind, label), ('else', label), ('end',).
DIAGRAMS = {
    'start-chat': {
        'title': 'Starting a chat',
        'participants': [
            ('app', 'Your app'), ('sdk', 'Protodesk SDK'), ('store', 'Keychain / Keystore'),
            ('api', 'Protodesk API'), ('ws', 'Realtime socket'),
        ],
        'steps': [
            ('call', 'app', 'sdk', 'initializeChat(options)'),
            ('call', 'sdk', 'store', 'read saved session'),
            ('group', 'alt', 'saved session'),
            ('call', 'sdk', 'api', 'POST /v1/chat/sessions/refresh'),
            ('else', 'signed-in user'),
            ('call', 'sdk', 'app', 'identityTokenProvider()'),
            ('reply', 'app', 'sdk', 'single-use token from your backend'),
            ('call', 'sdk', 'api', 'POST /v1/chat/sessions'),
            ('else', 'anonymous visitor'),
            ('call', 'sdk', 'api', 'POST /v1/chat/sessions/anonymous'),
            ('end',),
            ('reply', 'api', 'sdk', 'session'),
            ('call', 'sdk', 'store', 'save session'),
            ('reply', 'sdk', 'app', 'client ready'),
            ('call', 'app', 'sdk', 'show ChatMessenger'),
            ('call', 'sdk', 'api', 'GET /v1/chat/bootstrap'),
            ('reply', 'api', 'sdk', 'brand, greeting, Help Center'),
            ('call', 'sdk', 'api', 'POST /v1/chat/realtime/ticket'),
            ('reply', 'api', 'sdk', 'one-time ticket'),
            ('call', 'sdk', 'ws', 'connect (ticket, last cursor)'),
            ('reply', 'ws', 'sdk', 'ready + missed events'),
        ],
    },
    'send-message': {
        'title': 'Sending a message',
        'participants': [
            ('user', 'Customer'), ('ui', 'ChatMessenger'), ('queue', 'Send queue'),
            ('api', 'Protodesk API'), ('ws', 'Realtime socket'),
        ],
        'steps': [
            ('call', 'user', 'ui', 'types and taps Send'),
            ('call', 'ui', 'queue', 'enqueue(text, operationId)'),
            ('reply', 'queue', 'ui', 'bubble shows "Sending"'),
            ('group', 'loop', 'until accepted (bounded attempts)'),
            ('call', 'queue', 'api', 'POST …/messages, Idempotency-Key'),
            ('group', 'alt', 'offline, 429 or 503'),
            ('reply', 'api', 'queue', 'error or no response'),
            ('self', 'queue', 'wait, keep same ID and text'),
            ('else', 'accepted'),
            ('reply', 'api', 'queue', '201 message'),
            ('end',),
            ('end',),
            ('reply', 'ws', 'ui', 'message.created (deduplicated)'),
            ('self', 'ui', 'show the delivered message'),
        ],
    },
    'push-open': {
        'title': 'Opening a push notification',
        'participants': [
            ('app', 'Your app'), ('sdk', 'Protodesk SDK'), ('api', 'Protodesk API'),
            ('push', 'FCM / APNs / OneSignal'), ('user', 'Customer'),
        ],
        'steps': [
            ('call', 'app', 'sdk', 'createPushTargets().register(token)'),
            ('call', 'sdk', 'api', 'POST /v1/chat/push-targets'),
            ('note', 'api', 'push', 'later, an agent replies'),
            ('call', 'api', 'push', 'send notification'),
            ('call', 'push', 'user', 'notification on device'),
            ('call', 'user', 'app', 'taps it'),
            ('call', 'app', 'sdk', 'handlePushPayload(data)'),
            ('call', 'sdk', 'api', 'GET /v1/chat/conversations/{id}'),
            ('reply', 'api', 'sdk', 'conversation'),
            ('reply', 'sdk', 'app', 'onNavigate(conversation)'),
            ('self', 'app', 'open ChatMessenger at it'),
            ('call', 'sdk', 'api', 'POST /v1/chat/notifications/{id}/open'),
        ],
    },
}

FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
INK, MUTED, LINE, BRAND = '#18181b', '#52525b', '#a1a1aa', '#00a5d1'
COL, MARGIN, HEAD_H, ROW = 190, 24, 44, 34
# White outline under labels so lifelines don't strike through the text.
HALO = ' stroke="#ffffff" stroke-width="5" paint-order="stroke" stroke-linejoin="round"'


def text_width(text, size=13):
    return len(text) * size * 0.56


def render(spec):
    names = [p[0] for p in spec['participants']]
    x = {name: MARGIN + COL / 2 + i * COL for i, name in enumerate(names)}
    width = MARGIN * 2 + COL * len(names)
    out, y, frames = [], 56 + HEAD_H + 24, []

    def arrow(x1, x2, y, dashed):
        dash = ' stroke-dasharray="5 4"' if dashed else ''
        tip = -8 if x2 > x1 else 8
        out.append(f'<line x1="{x1}" y1="{y}" x2="{x2 + (2 if x2 < x1 else -2)}" y2="{y}" '
                   f'stroke="{INK}" stroke-width="1.3"{dash}/>')
        out.append(f'<path d="M{x2} {y} l{tip} -4.5 l0 9 z" fill="{INK}"/>')

    for step in spec['steps']:
        kind = step[0]
        if kind in ('call', 'reply'):
            _, a, b, label = step
            x1, x2 = x[a], x[b]
            out.append(f'<text x="{(x1 + x2) / 2}" y="{y - 7}" text-anchor="middle" '
                       f'font-size="12.5" fill="{INK}"{HALO}>{escape(label)}</text>')
            arrow(x1, x2, y, kind == 'reply')
            y += ROW
        elif kind == 'self':
            _, who, label = step
            x0 = x[who]
            out.append(f'<path d="M{x0} {y - 10} h28 v18 h-26" fill="none" stroke="{INK}" stroke-width="1.3"/>')
            out.append(f'<path d="M{x0} {y + 8} l8 -4.5 l0 9 z" fill="{INK}"/>')
            out.append(f'<text x="{x0 + 34}" y="{y + 3}" font-size="12.5" fill="{INK}"{HALO}>{escape(label)}</text>')
            y += ROW
        elif kind == 'note':
            _, a, b, label = step
            left, right = min(x[a], x[b]) - 70, max(x[a], x[b]) + 70
            out.append(f'<rect x="{left}" y="{y - 16}" width="{right - left}" height="24" rx="4" '
                       f'fill="#fef9c3" stroke="#eab308" stroke-width="0.8"/>')
            out.append(f'<text x="{(left + right) / 2}" y="{y + 1}" text-anchor="middle" font-size="12" '
                       f'font-style="italic" fill="{MUTED}">{escape(label)}</text>')
            y += ROW
        elif kind == 'group':
            frames.append({'kind': step[1], 'top': y - 22, 'labels': [(y - 22, step[2])], 'depth': len(frames)})
            y += 20
        elif kind == 'else':
            frames[-1]['labels'].append((y - 18, step[1]))
            y += 16
        elif kind == 'end':
            frame = frames.pop()
            inset = 8 + frame['depth'] * 8
            left, right = MARGIN + inset, width - MARGIN - inset
            bottom = y - 14
            box = [f'<rect x="{left}" y="{frame["top"]}" width="{right - left}" height="{bottom - frame["top"]}" '
                   f'rx="4" fill="none" stroke="{LINE}" stroke-width="1"/>']
            tag = frame['kind']
            box.append(f'<path d="M{left} {frame["top"]} h{text_width(tag, 11) + 16} v12 l-6 6 h-{text_width(tag, 11) + 10} z" '
                       f'fill="#f4f4f5" stroke="{LINE}" stroke-width="1"/>')
            box.append(f'<text x="{left + 6}" y="{frame["top"] + 13}" font-size="11" font-weight="600" '
                       f'fill="{MUTED}">{tag}</text>')
            for i, (ly, label) in enumerate(frame['labels']):
                if i:
                    box.append(f'<line x1="{left}" y1="{ly}" x2="{right}" y2="{ly}" stroke="{LINE}" '
                               f'stroke-dasharray="4 3"/>')
                lx = left + (text_width(tag, 11) + 24 if i == 0 else 8)
                box.append(f'<text x="{lx}" y="{ly + 13}" font-size="11.5" fill="{MUTED}"{HALO}>'
                           f'[{escape(label)}]</text>')
            out[:0] = box
            y += 8
    height = y + 14 + HEAD_H

    heads, lifelines = [], []
    for i, (name, label) in enumerate(spec['participants']):
        cx = x[name]
        box_w = min(COL - 16, max(110, text_width(label, 13) + 28))
        accent = name == 'sdk'
        fill, stroke = ('#e6f6fb', BRAND) if accent else ('#f4f4f5', LINE)
        lifelines.append(f'<line x1="{cx}" y1="{56 + HEAD_H}" x2="{cx}" y2="{height - HEAD_H - 8}" '
                         f'stroke="{LINE}" stroke-dasharray="4 4"/>')
        for top in (56, height - HEAD_H - 8):
            heads.append(f'<rect x="{cx - box_w / 2}" y="{top}" width="{box_w}" height="{HEAD_H - 8}" rx="8" '
                         f'fill="{fill}" stroke="{stroke}" stroke-width="1.2"/>')
            heads.append(f'<text x="{cx}" y="{top + 23}" text-anchor="middle" font-size="13" '
                         f'font-weight="600" fill="{INK}">{escape(label)}</text>')
    title = (f'<text x="{MARGIN}" y="34" font-size="16" font-weight="700" fill="{INK}">'
             f'{escape(spec["title"])}</text>')
    body = '\n'.join([title] + lifelines + out + heads)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}" font-family="{FONT}" role="img" '
            f'aria-label="{escape(spec["title"])} sequence diagram">\n'
            f'<rect width="{width}" height="{height}" rx="12" fill="#ffffff"/>\n{body}\n</svg>\n')


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, spec in DIAGRAMS.items():
        (OUT / f'{name}.svg').write_text(render(spec))
        print(OUT / f'{name}.svg')


if __name__ == '__main__':
    main()
