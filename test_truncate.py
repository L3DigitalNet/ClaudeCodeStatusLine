import re
from rich.cells import cell_len
from rich.style import Style

class Text:
    def __init__(self, value=""):
        self.segments = [(str(value), None)] if value else []
    @property
    def plain(self): return "".join(c for c, s in self.segments)
    def append_text(self, other): self.segments.extend(other.segments)
    def append(self, value):
        if value: self.segments.append((str(value), None))
    def __bool__(self): return bool(self.segments)

def combine(*parts):
    result = Text()
    for part in parts:
        if isinstance(part, Text): result.append_text(part)
        else: result.append(part)
    return result

def text(v): return Text(v)

def visible_len(value): return cell_len(value.plain)

def truncate_text(val, max_w):
    if visible_len(val) <= max_w: return val
    if max_w <= 1: return text("…")
    res = Text()
    curr_w = 0
    budget = max_w - 1
    for content, style in val.segments:
        if curr_w + cell_len(content) <= budget:
            res.segments.append((content, style))
            curr_w += cell_len(content)
        else:
            avail = budget - curr_w
            truncated = []
            for char in content:
                cw = cell_len(char)
                if curr_w + cw <= budget:
                    truncated.append(char)
                    curr_w += cw
                else: break
            if truncated: res.segments.append(("".join(truncated), style))
            break
    res.segments.append(("…", None))
    return res

def join_cells(cells):
    separator = combine(" ", text("|"), " ")
    result = Text()
    first = True
    for cell in cells:
        if not cell: continue
        if not first: result.append_text(separator)
        result.append_text(cell)
        first = False
    return result

cell_model_effort = text("model(med)") # 10
cell_elapsed = text("12:34") # 5
cell_tokens = text("100/200") # 7
cell_task = text("this is a very long task description") # 36

# max_columns = 60 (plenty of room)
# max_columns = 40 (requires truncating task)
# max_columns = 25 (requires dropping tokens or elapsed)

for max_columns in [70, 50, 40, 25, 20, 10]:
    cells = [cell_model_effort, cell_elapsed, cell_tokens, cell_task]
    line = join_cells(cells)
    
    if visible_len(line) > max_columns:
        candidates = [
            [cell_model_effort, cell_elapsed, cell_tokens, cell_task],
            [cell_model_effort, cell_tokens, cell_task],
            [cell_model_effort, cell_task]
        ]
        
        for candidate_cells in candidates:
            prefix_cells = candidate_cells[:-1]
            prefix_line = join_cells(prefix_cells)
            separator_len = 3 if prefix_line else 0
            
            avail_for_task = max_columns - visible_len(prefix_line) - separator_len
            
            if avail_for_task >= 6 or candidate_cells == candidates[-1]:
                target_w = max(6, avail_for_task)
                truncated_task = truncate_text(cell_task, target_w)
                cells = prefix_cells + [truncated_task]
                line = join_cells(cells)
                break
                
        if visible_len(line) > max_columns:
            line = truncate_text(line, max_columns)

    print(f"{max_columns:2}: {visible_len(line):2} {line.plain}")

