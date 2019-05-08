load("@bazel_skylib//lib:structs.bzl", "structs")
load("@bazel_skylib//lib:types.bzl", "types")

SourceFiles = provider(fields = ["files"])

def _source_files_impl(target, ctx):
    files = []
    transitive_depsets = []

    # skip external dependencies, we only care about things in our workspace
    if target.label.workspace_root.startswith("external/"):
        return []

    # try to determine the BUILD file for this target
    if hasattr(ctx.rule.attr, "generator_location") and ctx.rule.attr.generator_location:
        build_file = ctx.rule.attr.generator_location.split(":")[0]
        files.append(build_file)

    # record any file dependencies of this target. this is our main job.
    file_attrs = structs.to_dict(ctx.rule.files)
    for k, v in file_attrs.items():
        files += [f.path for f in v]

    # transitively record any files from targets that this target depends on
    attr = structs.to_dict(ctx.rule.attr)
    for k, v in attr.items():
        if types.is_list(v):
            for v2 in v:
                if type(v2) == "Target" and SourceFiles in v2:
                    transitive_depsets.append(v2[SourceFiles].files)
        elif type(v) == "Target" and SourceFiles in v:
            transitive_depsets.append(v[SourceFiles].files)

    return [
        SourceFiles(
            files = depset(
                files,
                transitive = transitive_depsets,
            ),
        ),
    ]

_source_files = aspect(
    implementation = _source_files_impl,
    doc = "Walk the dependency tree of a target and record all file dependencies.",
    attr_aspects = ["*"],
)

def _deps_for_target(target):
    return [
        f
        for f in target[SourceFiles].files.to_list()
        if not (
            f.startswith("bazel-out/") or
            f.startswith("external/")
        )
    ]

def _normalized_target(target):
    l = target.label
    return "//%s:%s" % (l.package, l.name)

def _tiltfile_impl(ctx):
    # collect dependencies for each image target
    image_targets = []
    for image, name in ctx.attr.images.items():
        image_targets.append({
            "ref": name,
            "target": _normalized_target(image),
            "deps": _deps_for_target(image),
            "live_update_sync": ctx.attr.live_update_sync.get(name, []),
            "live_update_fall_back_on": ctx.attr.live_update_fall_back_on.get(name, []),
        })

    # collect dependencies for each k8s_object target
    k8s_targets = []
    for k8s_obj in ctx.attr.k8s_objects:
        k8s_targets.append({
            "target": _normalized_target(k8s_obj),
            "deps": _deps_for_target(k8s_obj),
        })

    # format everything we collected into a JSON blob
    targets_json = struct(
        images = image_targets,
        k8s = k8s_targets,
    ).to_json()

    ctx.actions.write(
        output = ctx.outputs.out_json,
        content = targets_json,
    )

    return [
        DefaultInfo(
            runfiles = ctx.runfiles(files = [ctx.outputs.out_json]),
        ),
    ]

tilt_export = rule(
    implementation = _tiltfile_impl,
    doc = """Generate a Tiltfile for a set of image and k8s_object targets.
    To generate the Tiltfile, we walk the dependency tree of each image and
    k8s_object target, and create a JSON object that contains all the info
    that Tilt needs for each target.
    For a single image dependency and k8s_object, the JSON object might look
    like this:
        {
          "images": [
            {
              "ref": "my_app/image",
              "command": "bazel run //my_app:image",
              "deps": [
                "my_app/BUILD",
                "my_app/source_file_1",
                "some_lib/source_file_2"
              ]
            }
          ],
          "k8s": [
            {
              "command": "bazel run //my_app:k8s",
              "deps": [
                "my_app/BUILD",
                "my_app/k8s.yaml",
                "k8s/tilt.yaml"
              ]
            }
          ],
        }
    """,
    attrs = {
        "images": attr.label_keyed_string_dict(
            doc = "Mapping of image targets to Docker image names",
            aspects = [_source_files],
        ),
        "k8s_objects": attr.label_list(
            doc = "List of k8s_objects to deploy",
            aspects = [_source_files],
        ),
        "live_update_sync": attr.string_list_dict(
            doc = """Mapping of image names to local/remote paths for live update.
            For more details, see:
            https://docs.tilt.dev/api.html#api.sync
            These paths are naively injected into the corresponding image target
            in the generated JSON blob, and can be used by the Tiltfile template.
            """,
        ),
        "live_update_fall_back_on": attr.string_list_dict(
            doc = """Mapping of image names to files that require a full rebuild.
            This only necessary to specify if live_update_sync is specified, and
            if some files in the local path require a full image rebuild.
            These paths are naively injected into the corresponding image target
            in the generated JSON blob, and can be used by the Tilfile template.
            """,
        ),
    },
    outputs = {
        "out_json": "%{name}-tilt.json",
    },
)
