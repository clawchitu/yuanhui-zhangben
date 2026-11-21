// 测试用：设了 TEST_SHIFT_NOW（ISO 时间，例如 2027-01-15T10:00:00+08:00）时，把本进程的「现在」整体平移到那一刻，钟照常往前走。
// 用来证明测试不依赖真实日期：`TEST_SHIFT_NOW=2027-01-15T10:00:00+08:00 npm test`。没设时什么都不做。
// 只平移 JS 的 Date（new Date()、Date.now()）；Postgres 的 now() 不动——服务端代码的时间都从注入的 clock 来，不读库里的 now()。
const target = process.env.TEST_SHIFT_NOW;
if (target) {
  const RealDate = Date;
  const at = RealDate.parse(target);
  if (Number.isNaN(at)) throw new Error(`TEST_SHIFT_NOW 不是合法时间：${target}`);
  const offset = at - RealDate.now();
  class ShiftedDate extends RealDate {
    constructor(...args: unknown[]) {
      if (args.length === 0) super(RealDate.now() + offset);
      else super(...(args as [string | number | Date]));
    }
    static override now() {
      return RealDate.now() + offset;
    }
  }
  globalThis.Date = ShiftedDate as DateConstructor;
}
