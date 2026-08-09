# Auditoría diferencial de los motores de Zymbol

> **Idioma**: este documento está en español a petición explícita del autor del
> proyecto. El resto de la documentación de `zyml` está en inglés.

## Qué es esto y de dónde sale

Escribir un cuarto motor de Zymbol desde cero —`zyml`, en OCaml— obligó a
decidir, una por una, cosas que ninguna especificación fija. Cuando `GUIDE.md`
no decía nada, la única fuente de verdad disponible era el binario `zymbol`. Y
cuando el binario contradecía al `GUIDE`, o cuando el tree-walker contradecía a
la VM, eso era un hallazgo.

Este documento recoge esos hallazgos. **No propone cambiar nada**: cada entrada
termina con una recomendación, pero la decisión de implementar, deprecar o
desestimar es del autor del lenguaje.

### Método

Cada caso se ejecutó en los **cuatro** motores existentes:

| Motor | Cómo se invoca | Implementación |
|---|---|---|
| **TW** | `zymbol run f.zy` | Rust, tree-walker (motor por defecto) |
| **VM** | `zymbol run --vm f.zy` | Rust, VM de registros |
| **JS** | `web/src/zymbol/zymbol.js` | JavaScript, motor del playground |
| **ML** | `zyml run f.zy` | OCaml, closure compilation |

Un caso donde los cuatro coinciden no aparece aquí. Un caso donde discrepan es
un bug en alguno de ellos —o una decisión de diseño que nunca se tomó
explícitamente y que cada implementación resolvió a su manera.

Versión auditada: `zymbol 0.0.8`. Fecha: 2026-08-07.

---

## Resumen ejecutivo

**13 hallazgos.** Siete son divergencias reales entre motores; el gate de
paridad `tests/scripts/vm_compare.sh` no detecta ninguna de ellas.

> **Corrección (2026-08-07).** La versión inicial de este documento afirmaba en
> B5 que *"el value flow no existe, solo hay exception flow"*. **Era falso.**
> Los valores de error sí existen; lo que no existe es una forma de construir
> uno desde el lenguaje puro, y por eso todas las sondas escritas a mano
> devolvían `#0`. `std/io` sí los produce. B5 está reescrito abajo, y la
> comprobación destapó un hallazgo nuevo, A7.

| # | Hallazgo | TW | VM | JS | Gravedad |
|---|---|---|---|---|---|
| A1 | `#?` cuenta bytes en String | ✗ | ✓ | ✓ | **Alta** |
| A2 | `==` sobre arrays | ✓ | ✗ | ✓ | **Alta** |
| A3 | `^` con exponente entero negativo | ✓ | ✗ | ✗ | **Alta** |
| A4 | Desbordamiento de `^` | ✓ | ✗ | ✗ | **Alta** |
| A5 | `$??` con patrón vacío | ✗ | ✓ | ✓ | Media |
| A6 | `$/` con separador vacío | ~ | ~ | ~ | Media |
| A7 | `#?` sobre un valor de error | ✓ | ✗ | ✗ | **Alta** |
| B1 | `0x41` es Char, no Int | — | — | — | Doc |
| B2 | `$[0..n]` acepta el 0, `arr[0]` no | — | — | — | Diseño |
| B3 | Yuxtaposición concatena en `=`, `:=` y `<~` | — | — | — | Doc |
| B4 | `#.N` devuelve Float, `#,.N` devuelve String | — | — | — | Doc |
| B5 | `$!!` no propaga *en el lenguaje puro* | — | — | — | Doc |
| C2 | ~~`check` no verifica la aridad de `alias::fn`~~ **resuelto v0.0.8** | ✓ | ✓ | ✓ | Media |

`✓` = comportamiento que parece correcto · `✗` = incorrecto o divergente ·
`~` = los tres difieren · `—` = los tres coinciden, el problema es de
documentación o de diseño.

---

# A. Divergencias entre motores

Estas son las que importan: el mismo programa da respuestas distintas según
con qué motor se ejecute. Cada una es un agujero del gate de paridad.

## A1 — `#?` cuenta *bytes* en el tree-walker, *caracteres* en los demás

**Gravedad: alta.** Es el hallazgo que más código de usuario puede romper en
silencio, porque solo se manifiesta con texto no ASCII.

```zymbol
>> "héllo"#? ¶
>> ("héllo"$#) ¶
>> "日本語"#? ¶
>> ("日本語"$#) ¶
```

| Motor | `"héllo"#?` | `"héllo"$#` | `"日本語"#?` | `"日本語"$#` |
|---|---|---|---|---|
| TW | `(##", **6**, héllo)` | `5` | `(##", **9**, 日本語)` | `3` |
| VM | `(##", **5**, héllo)` | `5` | `(##", **3**, 日本語)` | `3` |
| JS | `(##", **5**, héllo)` | `5` | `(##", **3**, 日本語)` | `3` |
| ML | `(##", 6, héllo)` | `5` | `(##", 9, 日本語)` | `3` |

El tree-walker devuelve `String::len()` de Rust, que es la longitud **en
bytes**. La VM y JS devuelven la longitud en caracteres.

Tres razones por las que el tree-walker es el que está mal:

1. **`GUIDE.md` §18 lo dice explícitamente**: para String, `count` es
   *"character length"*.
2. **Contradice a `$#`** dentro del mismo motor: `"héllo"$#` da 5 y
   `"héllo"#?` da 6. Dos operadores del mismo lenguaje miden la misma cosa de
   dos maneras.
3. **Contradice la premisa del lenguaje.** Zymbol se define como Unicode-first
   y rastrea grafemas para posicionar errores. Un contador de bytes expuesto al
   usuario es ajeno a ese diseño.

`zyml` replica el bug porque su suite de paridad compara contra el
tree-walker, que es el motor por defecto. Cuando se corrija en Rust, `zyml`
lo seguirá.

> **Recomendación**: corregir el tree-walker para que cuente caracteres.
> Añadir un caso al corpus de paridad con texto no ASCII —el corpus actual no
> tiene ninguno que ejercite `#?` sobre multibyte, que es exactamente por qué
> `vm_compare.sh` no lo ve.

## A2 — `==` sobre arrays da `#0` en la VM

**Gravedad: alta.** Ya registrado, se confirma que sigue vivo en v0.0.8.

```zymbol
>> ([1,2,3] == [1,2,3]) ¶
```

| Motor | Resultado |
|---|---|
| TW | `#1` |
| VM | `#0` |
| JS | `#1` |
| ML | `#1` |

La VM es el outlier: tres motores dicen que dos arrays con los mismos
elementos son iguales, y ella dice que no. Comparar tuplas sí funciona en los
cuatro (`(1,2) == (1,2)` → `#1` en todos), lo que sugiere que a la VM le falta
el caso de `Array` en su rutina de igualdad, no que sea una decisión.

> **Recomendación**: corregir la VM. Es un caso aislado de una función que ya
> maneja bien las tuplas.

## A3 — `^` con exponente entero negativo

**Gravedad: alta**, porque es aritmética básica y el resultado no es "otro
formato": es un número distinto.

```zymbol
>> (2 ^ -1) ¶
>> (2 ^ -2) ¶
>> (2.0 ^ -1) ¶
```

| Motor | `2 ^ -1` | `2 ^ -2` | `2.0 ^ -1` |
|---|---|---|---|
| TW | `0.5` | `0.25` | `0.5` |
| VM | `0` | `0` | `0.5` |
| JS | `0` | `0` | `0.5` |
| ML | `0` | `0` | `0.5` |

Con base flotante los cuatro coinciden. Con base entera, el tree-walker
promociona a flotante y da el resultado matemático; la VM y JS hacen
exponenciación entera, que para exponente negativo colapsa a 0.

Aquí **no hay un motor obviamente correcto**: es una decisión de diseño que
nunca se tomó. Las dos posturas son defendibles:

- *`2 ^ -1` es `0.5`* — consistente con que `/` ya promociona
  (`10 / 4.0` → `2.5`), y con la intuición matemática.
- *`2 ^ -1` es `0`* — consistente con que `10 / 3` es `3`: si la división
  entera trunca, la potencia entera también.

Lo insostenible es el estado actual, donde depende del motor.

> **Recomendación**: decidir y documentarlo en §5 *Arithmetic*. Mi sugerencia
> es **promocionar a Float** (el comportamiento del tree-walker): `^` no tiene
> el precedente de la división entera —`10 / 3` es entero porque el usuario
> pidió dividir enteros, pero `2 ^ -1` **no tiene** resultado entero, y
> devolver `0` convierte un valor exacto en un error silencioso.

## A4 — Desbordamiento de `^`: cuatro motores, cuatro respuestas

**Gravedad: alta.** Este es el hallazgo más llamativo de la auditoría.

```zymbol
>> (10 ^ 20) ¶
```

| Motor | Resultado |
|---|---|
| TW | `Runtime error: power operation overflow: 10^20` |
| VM | `7766279631452241920` (wraparound de i64, silencioso) |
| JS | `100000000000000000000` (correcto: `1e20` es exacto en f64) |
| ML | `-1457092405402533888` (otro wraparound, distinto al de la VM) |

Cuatro implementaciones, cuatro resultados, **ninguno igual a otro**. Y dos de
ellos son valores numéricos plausibles que un programa aceptaría sin quejarse.

El tree-walker es el único que se comporta de forma defendible: detecta el
desbordamiento y falla en vez de devolver basura.

Nótese además la inconsistencia *dentro* de cada motor: `10 ^ 20` da error en
el tree-walker, pero la suma sí desborda en silencio en todos:

```zymbol
x = 9223372036854775807
>> (x + 1) ¶            // → -9223372036854775808 en TW y VM
```

Es decir, el tree-walker protege `^` pero no `+`.

> **Recomendación**: decidir una política de desbordamiento para **todo** el
> aritmético entero, no operador por operador. Tres opciones coherentes:
> (a) error en todos los operadores, (b) wraparound documentado en todos,
> (c) promoción automática a Float al desbordar. La (a) encaja mejor con la
> filosofía de Zymbol de hacer explícitos los errores —es la misma razón por
> la que `arr[0]` es un error en vez de devolver algo.
>
> Sea cual sea, `interpreter/REFERENCE.md` debería tener una sección
> *Desbordamiento numérico*, que hoy no existe.

## A5 — `$??` con patrón vacío

**Gravedad: media.** Caso límite, pero divergente.

```zymbol
s = "hello"
>> (s$?? "") ¶
```

| Motor | Resultado |
|---|---|
| TW | `[]` |
| VM | `[1, 2, 3, 4, 5, 6]` |
| JS | `[1, 2, 3, 4, 5, 6]` |
| ML | `[]` |

La cadena vacía aparece en todas las posiciones (incluida la de después del
último carácter: 6 posiciones para 5 caracteres), o en ninguna. La VM y JS
optan por lo primero, el tree-walker por lo segundo.

> **Recomendación**: `[]` (el comportamiento del tree-walker). "Encontrar la
> nada en todas partes" es formalmente correcto pero nunca es lo que quiere
> quien escribe el código, y devolver una lista de posiciones para un patrón
> que el usuario probablemente construyó por accidente esconde el error.

## A7 — `#?` sobre un valor de error da 0 en la VM

**Gravedad: alta.** Hallazgo nuevo, aparecido al comprobar B5.

```zymbol
<# std/io => io
x = io::read("no_existe.txt")
>> x#? ¶
```

| Motor | Resultado |
|---|---|
| TW | `(##IO, **38**, ##IO(No such file or directory (os error 2)))` |
| VM | `(##IO, **0**, ##IO(No such file or directory (os error 2)))` |
| JS | `(##IO, **0**, ##IO(No such file or directory (os error 2)))` |
| ML | `(##IO, 38, …)` |

`GUIDE.md` §18 dice que para un Error el `count` es *"length of the error
message"*. El mensaje tiene 38 caracteres, que es lo que da el tree-walker. La
VM y JS devuelven 0 — no miden nada.

Nótese la simetría con A1: allí el tree-walker es el único que falla, aquí es
el único que acierta. No hay un motor de referencia fiable para `#?`.

Es la misma familia que A1: `#?` es el operador con más divergencias de todo el
lenguaje, y en cada una un motor distinto es el que falla.

> **Recomendación**: corregir la VM. Y, ya que `#?` acumula A1 y A7, revisar su
> implementación entera en los tres motores contra la tabla de §18 en vez de
> caso por caso.

## A6 — `$/` con separador vacío: los tres motores difieren

**Gravedad: media.**

```zymbol
>> ("hello" $/ "") ¶
```

| Motor | Resultado |
|---|---|
| TW | `[, h, e, l, l, o, ]` (7 elementos: vacío + 5 chars + vacío) |
| VM | `[, h, e, l, l, o, ]` (igual que TW) |
| JS | `[h, e, l, l, o]` (5 elementos) |
| ML | `Runtime error: split separator must not be empty` |

El comportamiento de Rust es el de `str::split("")`, que produce cadenas
vacías en los bordes. El de JS es el de `String.split('')`, que no. `zyml`
rechaza la operación.

Ninguno está documentado. El de Rust es el más difícil de justificar: nadie
espera que partir `"hello"` por nada dé siete trozos, dos de ellos vacíos.

> **Recomendación**: unificar a **los caracteres, sin vacíos en los bordes**
> (el comportamiento de JS), que es lo que un usuario espera de "partir por
> nada". Alternativa igualmente válida: error explícito, como hace `zyml`.

---

# B. Comportamiento no documentado o mal documentado

Aquí los motores coinciden. El problema es que `GUIDE.md` no lo dice, o dice
otra cosa, y eso hace que quien implemente un motor nuevo lo adivine.

## B1 — Un literal con prefijo de base es un `Char`, no un `Int`

```zymbol
a = 0x41
>> a ¶          // → A     (no 65)
>> a#? ¶        // → (##', 1, A)
c = 0d300
>> c ¶          // → Ĭ     (el carácter U+012C)
```

`GUIDE.md` §1b *Numeric Literals* lo menciona de pasada bajo "Character
literals", pero §2 *Value Types* lista `0x41` en la fila de **Int**, y §18
*Base Literals and Conversions* dice *"result: Char if ASCII range, Int
otherwise"* — que es **falso**: `0d300` está fuera del rango ASCII y sigue
siendo Char.

Es el tipo de detalle que hace fallar una implementación nueva de forma
silenciosa: `0x41` como Int compila y corre, solo produce el número donde
debería producir la letra.

> **Recomendación**: corregir §18 (*siempre* Char, nunca Int) y quitar `0x41`
> de la fila de Int en la tabla de §2.

## B2 — `$[0..n]` acepta el índice 0; `arr[0]` es un error

```zymbol
s = "hello"
>> s$[0..3] ¶     // → hel   (el 0 se trata como 1)
>> s$[1..3] ¶     // → hel   (idéntico)
>> s[0] ¶         // → Runtime error: index 0 is invalid
```

Los cuatro motores coinciden, así que es el comportamiento real. Pero
`GUIDE.md` §11 dedica una subsección entera —*"Why 1-based Indexing"*— a
argumentar que **"el índice 0 es siempre un error"**, y remata:

> *"Accessing `arr[0]` raises `##Index` immediately, which makes accidental
> off-by-one bugs explicit rather than silently returning a wrong value."*

En un *slice*, ese mismo índice 0 no levanta nada: se corrige a 1 en silencio.
El argumento del diseño y su implementación van en direcciones opuestas, y en
el caso del slice hace exactamente lo que el texto dice querer evitar —
devolver algo en vez de señalar el error.

> **Recomendación**: hacer que `$[0..n]` sea un error, igual que `arr[0]`. Si
> se prefiere mantener el clamp por compatibilidad, documentarlo como
> excepción explícita en §11, porque hoy el `GUIDE` afirma lo contrario.

## B3 — La yuxtaposición concatena en `=`, `:=` y `<~`, no solo en `>>`

```zymbol
a = "x"
b = "y"
c = a " " b          // → "x y"
d := a "-" b         // → "x-y"
f() { <~ a " ok" }   // devuelve "x ok"
```

`GUIDE.md` presenta la yuxtaposición como una característica de `>>` (§3
*Output*, "Output uses juxtaposition (Haskell-style)"), y §5 *String
Concatenation* lista solo dos formas correctas: *"1. Juxtaposition in `>>`"* y
*"2. Interpolation"*.

Pero es un mecanismo general del lenguaje: funciona en el lado derecho de una
asignación, de una declaración de constante y de un `<~`. El corpus lo usa
—`interpreter/tests/output/03_comma_concat_assign.zy` y
`modules_scope/isolated_module.zy`— pero la guía no lo enseña.

Es una funcionalidad útil que está oculta a quien lea la documentación.

> **Recomendación**: promoverlo a su propia subsección en §5, con los tres
> contextos. Es más una carencia de documentación que un error.

## B4 — `#.N` devuelve Float; `#,.N` devuelve String con N decimales fijos

```zymbol
>> #.4|3.1| ¶        // → 3.1        (Float: los ceros no significativos se van)
>> #,.4|3.1| ¶       // → 3.1000     (String: N decimales exactos)
```

Los dos operadores comparten la sintaxis `.N` pero hacen cosas de distinta
naturaleza: uno redondea un **número**, el otro produce una **cadena
formateada**. §18 *Number Formatting* los presenta juntos sin distinguirlo.

No es un bug —es coherente una vez lo sabes— pero el `.N` compartido sugiere
que hacen lo mismo con distinto separador de miles, y no es así.

Relacionado: la mantisa de `#^` se imprime con el formato `{:?}` de Rust, que
siempre conserva parte decimal:

```zymbol
>> #^|100000| ¶      // → 1.0e5   (nunca "1e5")
```

Eso tampoco está documentado y es imposible de adivinar.

> **Recomendación**: añadir a §18 una frase por operador indicando el **tipo
> del resultado** (Float vs String), y documentar el formato de la mantisa de
> `#^`.

## B5 — `$!!` no propaga nada *en el lenguaje puro*

**Gravedad: documentación.** Reescrito tras la corrección de arriba: el
mecanismo funciona, pero solo se puede activar desde `std/*`, y el `GUIDE` no
lo dice.

`GUIDE.md` §16 dice:

> *"If the value is an error, `$!!` returns it **early** to the caller (the
> rest of the body never runs)"*

Y da este ejemplo:

```zymbol
process(value) {
    ? value < 0 {
        value$!!    // propagates error up to caller
    }
    <~ value * 2
}
```

Ejecutándolo:

```zymbol
f(v) { ? v < 0 { v$!! } <~ v * 2 }
>> f(5) ¶      // → 10
>> f(-3) ¶     // → -6      ← siguió ejecutando; no propagó nada
```

| Motor | `f(-3)` |
|---|---|
| TW | `-6` |
| VM | `-6` |
| JS | `-6` |
| ML | `-6` |

Los cuatro coinciden en no hacer lo que el ejemplo sugiere — pero no porque el
mecanismo falte, sino porque **`value` nunca es un error**. `$!!` solo actúa si
el valor *es* un error, y nada en el lenguaje puro construye uno:

```zymbol
x = 42
>> (x$!) ¶        // → #0
>> ([1,2]$!) ¶    // → #0
```

En cambio, con `std/*` de por medio funciona exactamente como está documentado:

```zymbol
<# std/io => io
x = io::read("no_existe.txt")
>> (x$!) ¶                          // → #1   ← es un valor de error
f(v) { ? v$! { v$!! } <~ "ok" }
>> f(x) ¶                           // → ##IO(No such file...)  ← propagó
>> f(42) ¶                          // → ok
```

Los cuatro motores coinciden en esto.

Así que el "value flow" de §16 **sí existe**; lo que falta es la frase que diga
de dónde salen los valores de error. Hoy solo los produce `std/*`: `io::read`
sobre un fichero inexistente, `json::decode` sobre entrada inválida, y las
funciones de `std/db`. Un `? v < 0 { v$!! }` como el del ejemplo de §16 no
propaga nada, porque `v` es un número, no un error.

> **Recomendación**: añadir a §16 una subsección *De dónde salen los valores de
> error*, con la lista de funciones que los devuelven, y sustituir el ejemplo de
> `process(value)` — que no propaga— por uno con `std/io`, que sí. Opcionalmente,
> dar al lenguaje una forma de construir un error, que hoy no tiene.

---

# C. Huecos del analizador estático

## C2 — `zymbol check` no verifica la aridad en llamadas de módulo

**Gravedad: media.** El analizador comprueba las llamadas a funciones locales y
no las de módulo, así que un error que sí detecta en una forma se le escapa en
la otra.

```zymbol
// m.zy
# m {
    #> { f }
    f(a) { <~ a }
}

// main.zy
<# ./m => m
>> m::f("x", "y") ¶        // dos argumentos a una función de uno
```

| Comprobación | Resultado |
|---|---|
| `zymbol check main.zy` | `No errors or warnings` |
| `zymbol run main.zy` | `Runtime error: function expects 1 arguments, got 2` |
| `zyml check main.zy` | `Compile error: 'm::f' expects 1 argument(s), got 2` |

La misma llamada escrita como función local (`f("x","y")`) **sí** la detecta el
analizador. Solo la forma `alias::fn` se le escapa.

Esto no es teórico: se encontró porque `zyml` rechazó `ZethyCLI/main.zy`, que
lleva en la línea 100 una llamada de dos argumentos a una función de uno.
`zymbol check` da ese fichero por bueno, y el error solo aparecería si la
ejecución llega a esa rama —el mensaje de "Ollama no accesible"—, que es
justamente el camino que menos se prueba.

> **Recomendación**: extender la comprobación de aridad del analizador a las
> llamadas `alias::fn`. La información está disponible: el analizador ya
> resuelve el módulo para saber que la función existe.

### Resuelto en v0.0.8 (2026-08-08)

Al implementarlo aparecieron **tres** huecos, no uno:

1. `alias::fn` de módulos de usuario — el reportado aquí.
2. `std::fn` — `math::sqrt(4.0, 9.0)` tampoco se verificaba, pese a que
   `zymbol_common::stdlib` ya guardaba la aridad de cada función nativa.
3. **La VM no verificaba nada.** `Instruction::Call` descartaba `arg_regs.len()`
   y copiaba todos los argumentos a la ventana de registros del callee, así que
   un argumento de más machacaba una local suya y el programa seguía; uno de
   menos dejaba el parámetro en `Unit`. Por eso `math::sqrt(4.0, 9.0)` imprimía
   `2` bajo `--vm` y lanzaba bajo el tree-walker.

El punto 3 era una divergencia TW/VM que el gate de paridad no veía. Ahora hay
corpus: `interpreter/tests/arity/` (6 casos). Ver REFERENCE.md L28.

**Rust adoptó el comportamiento de zyml.** La primera versión del arreglo levantaba
el error en el punto de llamada, y eso dejaba una incoherencia dentro del propio
Rust: `zymbol run` rechazaba el programa entero ante `f(a,b)` local mal llamada,
pero ejecutaba `m::f(a,b)` hasta el final si la llamada estaba en una rama muerta.
El mismo error, dos comportamientos, según cómo estuviera escrita la llamada.

La forma correcta es la que ya aplicaba el lenguaje a las llamadas locales, y la
que zyml aplicaba a todas: **error semántico, fatal antes de ejecutar**, en
`check`, `run` y `build`. Es lo que hay desde v0.0.8. La verificación es estática
y un desajuste de aridad nunca es intencional, así que no hay caso legítimo que
proteger.

Con eso los tres motores coinciden en comportamiento — `rc=1`, sin salida,
rechazo antes de ejecutar — y solo queda diferencia de **texto**:

```
Rust: error: function 's::saluda' expects 1 argument(s), but 2 were provided
zyml: Compile error: 's::saluda' expects 1 argument(s), got 2
```

Eso cae en la misma categoría que las otras cuatro diferencias de redacción ya
listadas, no en divergencia de comportamiento. `tests/parity.sh` las sigue
contando **UNSUP** porque decide por el mensaje de zyml sin llegar a comparar:
cinco de los 113 UNSUP actuales son de este tipo (ver README, *Correctness*).

La VM conserva su `RaiseError` en el punto de llamada como red de seguridad para
quien use compilador y VM por API sin análisis semántico; sin él,
`Instruction::Call` sigue copiando el argumento sobrante sobre un registro del
callee.

# D. Asimetría menor

## D1 — Los patrones de lista de `??` fallan como ítem de `>>`

```zymbol
n = 3
label = ?? n { [1,2] => "low"  [3,4] => "mid"  _ => "o" }   // ✅ funciona
>> (?? n { [1,2] => "low"  [3,4] => "mid"  _ => "o" }) ¶     // ❌ error de parseo
```

En los cuatro motores. El error es *"expected ']' after index"*: el valor de un
arm (`"low"`) absorbe el `[` del arm siguiente como si fuera una indexación.

`zyml` lo resuelve con una regla de línea —un `[` o `(` en otra línea que el
token anterior no continúa la expresión—, que es la misma regla que el parser
de Rust ya aplica en `parse_output_item_postfix` pero no en el valor de un arm
de `??`.

`GUIDE.md` solo muestra el caso de asignación, así que no está mal
documentado; simplemente el lenguaje es asimétrico donde no hay razón para
serlo.

> **Recomendación**: aplicar la restricción de misma línea al valor del arm en
> `parse_match_arm_value`. Coste bajo, y elimina una excepción que hoy hay que
> conocer de memoria.

## D2 — zyml aceptaba dos formas de escritura que Rust rechaza *(resuelto)*

Encontradas el 2026-08-08 escribiendo pruebas de semántica de valor: el
programa corría en zyml y no compilaba en Rust, que es la dirección menos
habitual de divergencia y la peor, porque el gate no la ve.

```zymbol
copia[1]$~ v      // zyml: statement válido
                  // Rust: error: expected '=' after index expression

m[1][2] = 77      // zyml: asignación indexada anidada
                  // Rust: error: expected '=' after index expression
```

**Ambas son incorrectas, y la razón está en el diseño del lenguaje, no en la
comodidad del parser.** El anidamiento se navega con `>`, no encadenando
corchetes: `m[i>j]` es la forma canónica de acceso (GUIDE §"Deprecated: Chained
`arr[i][j]`" marca la encadenada como deprecada, y solo para *lectura*). Y una
modificación tiene que declararse: en Zymbol no se pisa un valor por el hecho de
alcanzarlo, hay que decir `$~`. `m[1][2] = 77` rompe las dos reglas a la vez.

`copia[1]$~ v` suelto rompe otra cosa: `$~` es la forma **funcional**, devuelve
una colección nueva y deja la original intacta. Como statement el resultado se
descarta, así que la línea parece una modificación y no hace nada.

> **Resuelto en zyml el 2026-08-09**: rechaza las dos, con un mensaje que apunta
> a la forma correcta (`m = m[i>j]$~ value`). La lectura encadenada `m[1][2]`
> sigue funcionando, porque sigue siendo válida —deprecada— en la referencia.
> Regresión: `tests/rejects.sh`, enganchado a `make test`. Hace falta un test
> propio porque `parity.sh` puntúa como `UNSUP` todo programa rechazado, así que
> nunca habría visto ninguna de las dos.

## D3 — ~~zyml no implementa la navegación profunda `[i>j]`~~ *(mal diagnosticado)*

El diagnóstico original era falso. zyml **sí** implementa `[i>j]`, `[i>j>k]`,
átomos negativos y átomos calculados, y da resultados idénticos a Rust en todos.
Lo que faltaba era solo el **deep update**:

```zymbol
>> m[2>3] ¶          // ✅ ya funcionaba, idéntico a Rust
d2 = d1[1>2]$~ 77    // ❌ Compile error: '$~' needs an indexed target
```

Es decir: zyml aceptaba la forma equivocada de modificar anidado (`m[1][2] = 77`,
D2) y no soportaba la correcta. Empujaba al usuario hacia la sintaxis mala.

> **Resuelto en zyml el 2026-08-09**: `Update (Nav (base, NPath steps), v)`
> desciende desenganchando cada nivel —la misma disciplina de copy-on-write que
> usa la asignación indexada— y escribe la hoja. Solo pasos escalares, como
> manda GUIDE.md; un rango en la ruta cae al error de siempre. Subió un fichero
> del corpus de referencia de `UNSUP` a `PASS` (414 → 415). Regresión:
> `tests/cases/22_deep_update.zy`.

---

# D. Cómo reproducir

Todos los casos están en este documento como programas completos. Para
ejecutarlos en los cuatro motores:

```bash
# TW y VM
zymbol run caso.zy
zymbol run --vm caso.zy

# ML
zyml/zyml run caso.zy

# JS — pequeño arnés sobre el motor del playground
cat > js.mjs <<'EOF'
import { runZymbol } from './web/src/zymbol/zymbol.js';
import { readFileSync } from 'node:fs';
let out = '';
await runZymbol(readFileSync(process.argv[2], 'utf8'), () => '', s => out += s);
process.stdout.write(out);
EOF
node js.mjs caso.zy
```

## Por qué el gate de paridad no ve nada de esto

`interpreter/tests/scripts/vm_compare.sh` compara tree-walker contra VM sobre
el corpus de `interpreter/tests/`. Los seis hallazgos de la sección A pasan el
gate porque **ningún test del corpus los ejercita**:

| Hallazgo | Lo que faltaría en el corpus |
|---|---|
| A1 | Un `#?` sobre un String no ASCII |
| A2 | Un `==` entre dos arrays |
| A3 | Un `^` con exponente entero negativo |
| A4 | Cualquier operación entera que desborde |
| A5 | Un `$??` con patrón vacío |
| A6 | Un `$/` con separador vacío |

Son seis casos de prueba. Añadirlos convierte cada hallazgo de esta auditoría
en una regresión detectable, que es más valioso que corregirlos uno a uno sin
red.

> **Recomendación transversal**: antes de tocar código, añadir esos seis casos
> al corpus con la salida esperada que se decida. El gate pasará a fallar —esa
> es la señal de que ahora sí mide lo que decía medir.

---

# E. Estado de `zyml` frente a cada hallazgo

| # | Qué hace `zyml` hoy | Acción |
|---|---|---|
| A1 | Replica el bug del TW (bytes) | Seguir al TW cuando se corrija |
| A7 | Correcto (longitud del mensaje) | Ninguna |
| A2 | Correcto (`#1`) | Ninguna |
| A3 | Como VM y JS (`0`) | Seguir la decisión que se tome |
| A4 | Wraparound silencioso | Seguir la política que se defina |
| A5 | Como TW (`[]`) | Ninguna |
| A6 | Error explícito | Revisar según la decisión |
| B1–B4 | Coincide con la referencia | Ninguna |
| B5 | **Implementado**: `Err` es un valor, `$!`/`$!!` funcionan | — |
| C1 | **Ya corregido** (regla de línea) | — |

`zyml` replica deliberadamente los bugs A1 y A4 porque su definición de
correctitud es "salida byte a byte idéntica a `zymbol run`". Esa es la
propiedad que hace útil su suite de paridad, y también la que hace que herede
los defectos del motor de referencia. Cuando se corrija Rust, se corrige
`zyml`, y la suite lo verifica sola.

B5 dejó de ser un stub al implementarse `std/*`: `Err` es ahora un constructor
de valor, `$!` lo detecta y `$!!` lo devuelve al llamante. Fue precisamente esa
implementación la que obligó a corregir el diagnóstico original.

Un bug **propio** detectado durante esta auditoría, no compartido con ningún
otro motor:

```zymbol
>> ("a" == 'a') ¶     // TW/VM/JS → #0    ·    zyml → #1
```

`zyml` trata un String de un carácter y un Char como iguales. Los tres motores
de referencia no. Es un error de `zyml` y se corrige en él.
