# Copyright 2020 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load(
    ":mode.bzl",
    "LINKMODES",
)
load(
    ":platforms.bzl",
    "CGO_GOOS_GOARCH",
    "GOOS_GOARCH",
)
load(
    "@io_bazel_rules_go_name_hack//:def.bzl",
    "IS_RULES_GO",
)

def _filter_transition_label(label):
    """Transforms transition labels for the current workspace.

    This is a workaround for bazelbuild/bazel#10499. If a transition refers to
    a build setting in the same workspace, for example
    @io_bazel_rules_go//go/config:goos, it must use a label without a workspace
    name if and only if the workspace is the main workspace.

    All Go build settings and transitions are in io_bazel_rules_go. So if
    io_bazel_rules_go is the main workspace (for development and testing),
    go_transition must use a label like //go/config:goos. If io_bazel_rules_go
    is not the main workspace (almost always), go_transition must use a label
    like @io_bazel_rules_go//go/config:goos.
    """
    if IS_RULES_GO and label.startswith("@io_bazel_rules_go"):
        return label[len("@io_bazel_rules_go"):]
    else:
        return label

def go_transition_wrapper(kind, transition_kind, name, **kwargs):
    """Wrapper for rules that may use transitions.

    This is used in place of instantiating go_binary or go_transition_binary
    directly. If one of the transition attributes is set explicitly, it
    instantiates the rule with a transition. Otherwise, it instantiates the
    regular rule. This prevents targets from being rebuilt for an alternative
    configuration identical to the default configuration.
    """
    transition_keys = ("goos", "goarch", "pure", "static", "msan", "race", "gotags", "linkmode")
    need_transition = any([key in kwargs for key in transition_keys])
    if need_transition:
        transition_kind(name = name, **kwargs)
    else:
        kind(name = name, **kwargs)

def go_transition_rule(**kwargs):
    """Like "rule", but adds a transition and mode attributes."""
    kwargs = dict(kwargs)
    kwargs["attrs"].update({
        "goos": attr.string(
            default = "auto",
            values = ["auto"] + {goos: None for goos, _ in GOOS_GOARCH}.keys(),
        ),
        "goarch": attr.string(
            default = "auto",
            values = ["auto"] + {goarch: None for _, goarch in GOOS_GOARCH}.keys(),
        ),
        "pure": attr.string(
            default = "auto",
            values = ["auto", "on", "off"],
        ),
        "static": attr.string(
            default = "auto",
            values = ["auto", "on", "off"],
        ),
        "msan": attr.string(
            default = "auto",
            values = ["auto", "on", "off"],
        ),
        "race": attr.string(
            default = "auto",
            values = ["auto", "on", "off"],
        ),
        "gotags": attr.string_list(default = []),
        "linkmode": attr.string(
            default = "auto",
            values = ["auto"] + LINKMODES,
        ),
        "_whitelist_function_transition": attr.label(
            default = "@bazel_tools//tools/whitelists/function_transition_whitelist",
        ),
    })
    kwargs["cfg"] = go_transition
    return rule(**kwargs)

def _go_transition_impl(settings, attr):
    settings = dict(settings)
    goos = getattr(attr, "goos", "auto")
    goarch = getattr(attr, "goarch", "auto")
    pure = getattr(attr, "pure", "auto")
    _check_ternary("pure", pure)
    if goos != "auto" or goarch != "auto":
        if goos == "auto":
            fail("goos must be set if goarch is set")
        if goarch == "auto":
            fail("goarch must be set if goos is set")
        if (goos, goarch) not in GOOS_GOARCH:
            fail("invalid goos, goarch pair: {}, {}".format(goos, goarch))
        cgo = pure == "off"
        if cgo and (goos, goarch) not in CGO_GOOS_GOARCH:
            fail('pure is "off" but cgo is not supported on {} {}'.format(goos, goarch))
        platform = "@io_bazel_rules_go//go/toolchain:{}_{}{}".format(goos, goarch, "_cgo" if cgo else "")
        settings["//command_line_option:platforms"] = platform
    if pure != "auto":
        pure_label = _filter_transition_label("@io_bazel_rules_go//go/config:pure")
        settings[pure_label] = pure == "on"

    _set_ternary(settings, attr, "static")
    _set_ternary(settings, attr, "race")
    _set_ternary(settings, attr, "msan")

    tags = getattr(attr, "gotags", [])
    if tags:
        tags_label = _filter_transition_label("@io_bazel_rules_go//go/config:tags")
        settings[tags_label] = tags

    linkmode = getattr(attr, "linkmode", "auto")
    if linkmode != "auto":
        if linkmode not in LINKMODES:
            fail("linkmode: invalid mode {}; want one of {}".format(linkmode, ", ".join(LINKMODES)))
        linkmode_label = _filter_transition_label("@io_bazel_rules_go//go/config:linkmode")
        settings[linkmode_label] = linkmode

    return settings

go_transition = transition(
    implementation = _go_transition_impl,
    inputs = [_filter_transition_label(label) for label in [
        "//command_line_option:platforms",
        "@io_bazel_rules_go//go/config:static",
        "@io_bazel_rules_go//go/config:msan",
        "@io_bazel_rules_go//go/config:race",
        "@io_bazel_rules_go//go/config:pure",
        "@io_bazel_rules_go//go/config:tags",
        "@io_bazel_rules_go//go/config:linkmode",
    ]],
    outputs = [_filter_transition_label(label) for label in [
        "//command_line_option:platforms",
        "@io_bazel_rules_go//go/config:static",
        "@io_bazel_rules_go//go/config:msan",
        "@io_bazel_rules_go//go/config:race",
        "@io_bazel_rules_go//go/config:pure",
        "@io_bazel_rules_go//go/config:tags",
        "@io_bazel_rules_go//go/config:linkmode",
    ]],
)

def _check_ternary(name, value):
    if value not in ("on", "off", "auto"):
        fail('{}: must be "on", "off", or "auto"'.format(name))

def _set_ternary(settings, attr, name):
    value = getattr(attr, name, "auto")
    _check_ternary(name, value)
    if value != "auto":
        label = _filter_transition_label("@io_bazel_rules_go//go/config:{}".format(name))
        settings[label] = value == "on"
