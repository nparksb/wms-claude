---
name: wms2-sdr-param-conversion-500-is-a-commons-exception
description: "An SDR search query-param that won't convert 500s via QueryMethodParameterConversionException — in spring-data-COMMONS, extends RuntimeException, matched only through its cause; a MISSING primitive param is a different mechanism and still 500s"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 71657bb8-afdf-47d1-8cac-f5db05eda6e2
  modified: 2026-09-18T14:05:06.962Z
---

**A Spring Data REST search parameter that cannot be converted returns 500, and the exception is not where you'd look for it.** Fixed for wms2-api by SBDEV-3420 (PR #381); this is the mechanism, which is reusable.

`ReflectionRepositoryInvoker.prepareParameters` → private `convert`:

```java
try { return conversionService.convert(value, TypeDescriptor.forObject(value), new TypeDescriptor(parameter)); }
catch (ConversionException o_O) { throw new QueryMethodParameterConversionException(value, parameter, o_O); }
```

- **`QueryMethodParameterConversionException` lives in `spring-data-commons`** (`org.springframework.data.repository.support`), **NOT** spring-data-rest. Grepping only the `spring-data-rest-*` jars says the class does not exist — it does. It `extends RuntimeException`: not a `ConversionException`, not a `ConversionFailedException`, not a `TypeMismatchException`.
- It therefore matches **nothing in SDR's `RepositoryRestExceptionHandler` by its own type**. Spring falls back to `getCause()`, finds the `ConversionFailedException`, and lands on `handleMiscFailures`, declared `INTERNAL_SERVER_ERROR`. Because that handler's parameter is the widest `Exception`, Spring passes the **original** exception — which is why the body nests `QMPCE -> ConversionFailedException -> NumberFormatException` rather than starting at the conversion failure. **That nesting is the fingerprint**; a *bare* `{"status":500,…}` with no `cause` is the different, SBDEV-3417 rendering defect.
- **The fix is one `@ExceptionHandler(QueryMethodParameterConversionException.class)`** in a `@ControllerAdvice`. It covers the whole search surface *by construction* — every exported search binds through that one `convert` call — so no route list is needed and later-added searches are covered. `getParameter()`/`getSource()` let the 400 name the offending parameter.
- **Ordering works and the rule is stronger than usually stated:** Spring uses the first *applicable* advice with a handler for the exception **or any exception in its cause chain** (`ExceptionHandlerMethodResolver.resolveExceptionMapping`). So a **cause**-match in a higher-ordered advice beats a **direct** match in a lower one — exactly what lets an unscoped `@Order(0)` advice beat SDR's package-scoped, unordered one. SDR inserting its own resolver at chain index 0 doesn't matter: it's built with the full `ApplicationContext`, so it sees every advice, order-sorted.

⚠ **`MethodArgumentTypeMismatchException` is the MVC binder's exception and is NOT on this path.** Don't reach for it. Handling `ConversionFailedException` instead also works via cause traversal but is strictly broader.

⚠ **A MISSING required primitive param is a DIFFERENT mechanism and still 500s** — and the exception is **an `IllegalArgumentException` WRAPPING a `NullPointerException`**, which is neither of the two things people guess. Measured 2026-09-18 (SBDEV-3428) via MockMvc `getResolvedException()`, and confirmed against JDK 21 source:

```
IllegalArgumentException  @ ReflectionRepositoryInvoker.invoke:220
  message = "java.lang.NullPointerException: Cannot invoke \"java.lang.Number.intValue()\" because
             the return value of \"sun.invoke.util.ValueConversions.primitiveConversion(…)\" is null"
  caused by NullPointerException @ sun.invoke.util.ValueConversions.unboxInteger:81
```

`DirectMethodHandleAccessor.invoke` catches the unboxing NPE and rethrows `new IllegalArgumentException(e)`; the `(Throwable)` ctor sets `message = cause.toString()`, which is why the message is the NPE text. **The message is NOT `"argument type mismatch"`** — that string comes from the *sibling* `ClassCastException | WrongMethodTypeException` branch of the same method (deliberately with no cause). Grepping for it finds nothing and sends you to the wrong handler; an earlier revision of this memory and three javadocs all asserted it.

**Both naive readings are wrong, in opposite directions.** The response body's `message` field shows the NPE text, so the body reads as though an NPE were thrown — SBDEV-3428's ticket concluded exactly that and asked for the comment to say "NPE, not IAE". That is also wrong: the *resolved* type really is an IAE, and **the no-hijack argument depends on it** — widening the handler to `IllegalArgumentException` would catch every IAE in the app and relabel real server bugs as client errors, so don't. Say "IAE wrapping an NPE" and cite the resolved type, not the body.

Remedy is to withdraw the route — **not** to box the param, unless you also fix the predicate. `getForRapidPickingScanPackage` was withdrawn by SBDEV-3428 for exactly this reason: its predicate is `co.state != :stateCancelled`, and a boxed `null` makes that NULL for every row under three-valued logic, returning `Optional.empty()` silently. A loud 500 beats a silent wrong answer.

⚠ **The mechanism is NOT closed.** A runtime `ResourceMappings` enumeration counts **32 exported searches across 14 domain types** declaring ≥1 primitive param, each a candidate for the same 500 (`SdrOmittedPrimitiveParamSearchContextTest` prints the inventory). That instrument proves *declaration, not behaviour*, and the observed status is guard-mode-dependent. A source parse keyed on `@Param` **under**-counts — some searches declare bare params with no `@Param` at all.

⚠ **`MethodParameter.getParameterType().getSimpleName()` erases generics**, so a `Set<Long>` param yields "must be a valid Set" — the caller's `Set` spelling was never the problem, its element was. Use `ResolvableType.forMethodParameter(...)`.

Also: `java.util.Date` has a public deprecated `Date(String)` ctor and `DefaultConversionService` registers `ObjectToObjectConverter` last-resort, so a `Date.parse` spelling binds even though **no** ISO-8601 spelling does. "No ISO format works" is true; "unreachable" is not.

See also [[wms2-problemdetail-properties-nest-on-every-channel]], [[wms2-sdr-is-gatable-via-mappedinterceptor-bean]], [[sdr-exported-false-grep-matches-method-level]].
