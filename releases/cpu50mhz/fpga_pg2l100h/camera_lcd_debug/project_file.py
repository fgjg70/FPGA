from datetime import datetime
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent
TEMPLATE = ROOT.parents[1] / "ebf_pg2l100h_demo/20_hdmi_colorbar/pds_prj/hdmi_colorbar.pds"
TOP = "top_pg2l100h_camera_lcd"


def parse_project(text):
    tokens = iter(re.findall(r'"(?:\\.|[^"\\])*"|[()]|[^\s()]+', text))

    def parse_list():
        items = []
        for token in tokens:
            if token == ")":
                return items
            items.append(parse_list() if token == "(" else token)
        raise ValueError("Unbalanced PDS project parentheses")

    if next(tokens) != "(":
        raise ValueError("Invalid PDS project")
    result = parse_list()
    if next(tokens, None) is not None:
        raise ValueError("Unexpected trailing PDS project data")
    return result


def format_project(form, depth=0):
    indent = "    " * depth
    if not any(isinstance(item, list) for item in form):
        return indent + "(" + " ".join(form) + ")"
    first_child = next(index for index, item in enumerate(form) if isinstance(item, list))
    text = indent + "(" + " ".join(form[:first_child]) + "\n"
    for child in form[first_child:]:
        if not isinstance(child, list):
            raise ValueError("Unexpected atom after nested PDS form")
        text += format_project(child, depth+1) + "\n"
    return text + indent + ")"


def prepare_project(destination, sources, top=TOP, project_name="pg2l100h_camera_lcd", constraint="pg2l100h_camera_lcd.fdc"):
    original = parse_project(TEMPLATE.read_text(encoding="utf-8"))

    def file_form(path, name, file_format, top=None):
        item = ["_file", json.dumps(name)]
        if top:
            item.extend(["+", json.dumps(top)])
        item.extend([["_format", file_format],
                     ["_timespec", json.dumps(datetime.fromtimestamp(path.stat().st_mtime).isoformat(timespec="seconds"))]])
        return item

    def clean(form):
        tag = form[0]
        if tag in ["_output", "_db_output", "_timespec"]:
            return None
        if tag == "_gci_state":
            return [tag, ["_integer", "0"]]
        if tag == "_comment":
            return [tag, json.dumps(f"PG2L100H OV7670 FIFO + AN430; top {top}; prepared from EBF Logos2 project template")]
        if tag == "_status":
            return [tag, json.dumps("initial")]
        if tag == "_widget":
            widget = form[1]
            if widget == "wgt_my_design_src":
                files = []
                for source in sources:
                    files.append(file_form(source, "rtl/"+source.name, "verilog", top if source.stem == top else None))
                return [tag, widget, ["_input", *files]]
            if widget in ["wgt_my_ips_src", "wgt_simulation"]:
                return [tag, widget]
            if widget == "wgt_import_logic_con_file":
                return [tag, widget, ["_input", file_form(destination / constraint, constraint, "fdc")]]
        result = []
        for item in form:
            child = clean(item) if isinstance(item, list) else item
            if child is not None:
                result.append(child)
        if tag == "_command" or (tag == "_widget" and form[1] != "wgt_select_arch"):
            result = [item for item in result if not isinstance(item, list) or item[0] != "_input"]
        if tag == "_command" and form[1] == "cmd_compile":
            result.extend([["_option", "top_module", ["_string", json.dumps(top)]],
                           ["_option", "compiler_directives", ["_string", json.dumps("SYNTHESIS")]]])
        return result

    text = format_project(clean(original))+"\n"
    parse_project(text)
    project = destination / f"{project_name}.pds"
    project.write_text(text, encoding="utf-8")
    return project
