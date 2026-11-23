# Identity declaration fixture

Three independent overlays reuse the five-seat reader-workplace fixture. Each materializes a configuration clone with the shared Identity layer listed between Agents and Host. The destination must be new and its parent must exist.

```sh
bash tests/fixtures/identity-workplace/prepare.sh workplace-held /absolute/new/config
bash tests/fixtures/identity-workplace/prepare.sh workplace-none /another/new/config
bash tests/fixtures/identity-workplace/prepare.sh absent /third/new/config
```

Choose one command per configuration. Each copies the baseline layers, programs and tmux.conf, adds the shared Identity body, and overlays the selected scoped Identity files. It copies no PLAN/, BUILD/ or runtime data. The absent case adds no Identity files. The script neither plans nor builds nor starts a workplace.

The surface is `key : held` or `key : none`. File location supplies the scope; there is no user-written scope word. Identity uses its own optional IDENTITY.typify files because another layer's file is not a union of language bodies. The resulting recorded terms are `key A B C SCOPE STATE`; captured names lead the auxiliary write key, followed by the literal scope. Nothing generates, loads or exports a key.

Three inputs are necessary: inheritance from workplace held, a room override of workplace none, and complete absence require three mutually exclusive workplace settings. There are five authored lines in all. The additional office line measures the fourth scope rather than leaving its form untested.

Independent expected results and conflicting-state variants are kept outside this repository for comparison with the frame. This fixture measures the declaration and recorded-term interface. It does not claim a working Identity fold, key generation, private-key isolation, signing, SSH authentication or socket isolation.
