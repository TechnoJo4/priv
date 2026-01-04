export const assert = <T>(v: T | undefined, err: string): T => {
    if (v === undefined) throw new Error(err);
    return v;
}

export const pipe = <T, R>(v: T | undefined, f: (t: T) => R): R | undefined => v === undefined ? undefined : f(v);
