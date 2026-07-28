# Data 09: Conditional Application Autoconfiguration

> **For Codex:** REQUIRED SKILLS: `executing-plans`,
> `test-driven-development`, and `verification-before-completion`.

**Goal:** Let optional packages declare marker-driven Application extensions
without adding package-specific logic to Application or DI.

**Architecture:** `LF::Application` performs compile-time selection and ordered
installation of generic `ApplicationExtension` types. Data will consume this
contract later; this plan contains no Data references.

**Delivery prerequisite:** Plans 01 through 08 are merged. This contract has no
code dependency on Data, but it is intentionally delivered only after the
standalone Data layer is complete and usable without Application.

---

## Public Contract

An optional package declares its marker and extension:

```crystal
module LF::AutoConfig
  annotation Example
  end
end

@[LF::ApplicationAutoConfiguration(
  enabled_by: LF::AutoConfig::Example,
  priority: 100
)]
class ExampleExtension
  include LF::ApplicationExtension

  def configure(context : LF::ApplicationContext) : Nil
  end

  def stop : Nil
  end
end
```

An executable activates it:

```crystal
@[LF::Application]
@[LF::AutoConfig::Example]
class ExampleApplication
end
```

`priority` defaults to zero. Higher priority installs first. Equal priority is
ordered by fully qualified extension name. Shutdown remains reverse install
order.

## Task 1: Add Compile-Time Descriptor Validation

**Files**

- Modify: `src/opal/application.cr`
- Modify: `spec/application_compile_spec.cr`
- Create: `spec/fixtures/application/autoconfiguration_valid.cr`
- Create: `spec/fixtures/application/autoconfiguration_invalid_priority.cr`
- Create: `spec/fixtures/application/autoconfiguration_missing_marker.cr`
- Create: `spec/fixtures/application/autoconfiguration_requires_arguments.cr`

Write failing fixtures in this order:

1. valid descriptor and marked application compile;
2. descriptor priority must be an integer literal;
3. `enabled_by` is mandatory;
4. extension requires a zero-argument constructor;
5. a descriptor type must implement `ApplicationExtension`.

Compiler messages include the extension type and invalid attribute. Validation
must run only when the optional package is required.

## Task 2: Select Enabled Extensions

**Files**

- Create: `spec/application_autoconfiguration_spec.cr`
- Create: `spec/fixtures/application/autoconfiguration_without_marker.cr`

Extend the existing application `macro finished` generation:

1. collect classes annotated with `LF::ApplicationAutoConfiguration`;
2. compare each descriptor's marker type with annotations on the one
   `@[LF::Application]` class;
3. discard descriptors whose markers are absent;
4. sort enabled descriptors by descending priority, then type name.

Requiring an optional package without placing its marker on the application
must compile and install nothing.

Do not add a global runtime registry. The generated bootstrap contains direct
constructor and `runtime.install` calls for enabled extensions only.

## Task 3: Install Extensions During Bootstrap

Update generated bootstrap ordering to:

```text
create DI container
register service/configuration providers
create ApplicationRuntime
install enabled compile-time extensions
return runtime
```

On extension installation failure:

- `ApplicationRuntime#install` performs its existing extension cleanup;
- already installed extensions stop in reverse order;
- the DI container shuts down once;
- the original error is preserved unless cleanup also fails;
- bootstrap never returns a closed runtime.

Tests use probe extensions to verify configure and stop event order.

## Task 4: Protect Existing Boundaries

Add regression coverage proving:

- standalone DI executables still compile;
- an Application with no optional markers behaves identically;
- existing `LF::ApplicationConfiguration` priority/order is unchanged;
- current `@[LF::AutoConfig::HTTP]` still generates and runs `run_http`;
- `src/opal/application.cr` contains no Data or HTTP-specific branch;
- `src/opal/di.cr` is unchanged.

Do not migrate HTTP to the generic descriptor in this plan. HTTP owns an
executable entrypoint and has different installation needs; that migration
requires a separate ADR if desired.

## Verification

```bash
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec \
  spec/application_spec.cr \
  spec/application_compile_spec.cr \
  spec/application_autoconfiguration_spec.cr \
  spec/http_autoconfig_spec.cr \
  spec/run_http_process_spec.cr --no-color
CRYSTAL_CACHE_DIR=/tmp/opal-crystal-cache crystal spec --no-color
git diff --check
```

Commit as:

```text
feat(application): support conditional autoconfiguration
```

Stop for API and boundary review before Data consumes the contract.
