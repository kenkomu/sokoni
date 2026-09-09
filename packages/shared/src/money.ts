/**
 * Money.
 *
 * Held as a bigint of base units plus its decimal scale. Never a float: 0.1+0.2
 * is a rounding bug that costs real money, and JS numbers lose integer
 * precision above 2^53 which a token with 18 decimals passes trivially.
 *
 * Tokens on Monad do not share a scale — AUSD and USDC are 6 decimals, MON and
 * WMON are 18 — so the scale travels with the value rather than living in a
 * constant someone will forget to change.
 */
export class Money {
  readonly units: bigint;
  readonly decimals: number;

  constructor(units: bigint, decimals: number) {
    this.units = units;
    this.decimals = decimals;
  }

  static from(value: string, decimals: number): Money {
    const trimmed = value.trim();
    if (!/^-?\d+(\.\d+)?$/.test(trimmed)) throw new Error(`not a decimal string: ${value}`);
    const neg = trimmed.startsWith('-');
    const [whole = '0', frac = ''] = (neg ? trimmed.slice(1) : trimmed).split('.');
    if (frac.length > decimals) {
      // Refuse rather than silently truncating a user's amount.
      throw new Error(`${value} has more precision than ${decimals} decimals`);
    }
    const units = BigInt(whole + frac.padEnd(decimals, '0'));
    return new Money(neg ? -units : units, decimals);
  }

  /** Decimal string. This is the only representation that crosses the API. */
  toString(): string {
    const neg = this.units < 0n;
    const abs = neg ? -this.units : this.units;
    const s = abs.toString().padStart(this.decimals + 1, '0');
    const whole = s.slice(0, s.length - this.decimals);
    const frac = this.decimals ? s.slice(s.length - this.decimals).replace(/0+$/, '') : '';
    return `${neg ? '-' : ''}${whole}${frac ? '.' + frac : ''}`;
  }

  toJSON(): string { return this.toString(); }

  #same(o: Money): void {
    if (o.decimals !== this.decimals) {
      throw new Error(`scale mismatch: ${this.decimals} vs ${o.decimals}`);
    }
  }

  add(o: Money): Money { this.#same(o); return new Money(this.units + o.units, this.decimals); }
  sub(o: Money): Money { this.#same(o); return new Money(this.units - o.units, this.decimals); }
  isZero(): boolean { return this.units === 0n; }
  gte(o: Money): boolean { this.#same(o); return this.units >= o.units; }

  /** Rescale to another token's decimals. Throws if it would lose precision. */
  rescale(decimals: number): Money {
    if (decimals === this.decimals) return this;
    if (decimals > this.decimals) {
      return new Money(this.units * 10n ** BigInt(decimals - this.decimals), decimals);
    }
    const div = 10n ** BigInt(this.decimals - decimals);
    if (this.units % div !== 0n) throw new Error(`rescale to ${decimals} would lose precision`);
    return new Money(this.units / div, decimals);
  }
}
