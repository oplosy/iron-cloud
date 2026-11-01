# Platform Structure Notes

Working notes on how the platform layer is organized.

## Layers

1. Base platform setup that everything assumes.
2. Department-level configuration layered on top.
3. Local experiments in `lab/` that may one day move up a layer.

## Rules of thumb

- Lower layers should stay boring and stable.
- Changes that cross layers land from the bottom up.
- If a department needs something, other departments will too — hoist it once it is proven.

Nothing here is enforced by CI yet; consider this the current agreement.
