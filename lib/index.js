/**
 * dsh-plugin-keep-grouped —— 宿主端。
 *
 * 解决的问题
 * ----------
 * DSH 判断「一个会话属于哪个工作区」用的是**路径字符串严格相等**：
 *
 *     candidateMatches(id, path) =
 *         sessionPaths.get(id) === path || missingSessionPaths.has(id)
 *
 * 其中 sessionPaths 里的值是 `realpathNormalize(header.cwd)` 的结果。
 * 而 realpathNormalize 失败时（网络路径暂时不可达、SMB 未就绪、VPN 未连上…），
 * 只有 **ENOENT** 会被容忍（进 missingSessionPaths），其余错误
 * （ETIMEDOUT / ECONNRESET / ENETUNREACH / EHOSTUNREACH …）都会把会话
 * 记进 invalidSessionPaths ⇒ candidateMatches 返回 false ⇒
 * **该会话从工作区分组里消失，掉进「未分组」**。
 *
 * 典型场景：工作区指向 UNC 路径（\\server\share\dir），开机后 DSH 先启动、
 * 网络后就绪。此时会话全部掉进「未分组」；之后网络恢复也不会自动回来
 * （要重启 DSH）。用户看到的就是「一开就掉分组」。
 *
 * 本插件怎么做
 * ------------
 * 不碰 asar、不改 DSH 源码，只在 workspaceRegistry 服务就绪后，
 * **包装它的 host.candidateMatches**：
 *
 *   1. 先走原逻辑（网络正常时行为完全不变）；
 *   2. 原逻辑返回 false 时，退回「header.cwd 与工作区 path 的**原样字符串**比较」。
 *
 * 这样即使 realpath 失败，只要会话记录的 cwd 与工作区路径字面一致，
 * 会话就仍然留在原分组。网络恢复后，原逻辑自然接管，一切照旧。
 *
 * 为什么安全
 * ----------
 * · 只在「原本会被踢出分组」的情况下兜底，不改变任何正常路径的行为；
 * · 比较的仍是 header.cwd（会话真实记录的目录），不是瞎猜；
 * · 不写入任何持久化状态，纯运行时补丁，卸载即恢复原状。
 */

export const name = 'keep-grouped';

/**
 * 硬依赖 workspaceRegistry：没有它这个插件无事可做。
 * 用 inject 而不是 ctx.get()，是为了确保只在服务就绪后才动手。
 */
export const inject = ['workspaceRegistry'];

/** 归一化路径末尾的分隔符，仅用于兜底比较（不做大小写折叠，Windows 由调用方保证一致）。 */
function trimTrailingSep(p) {
  if (typeof p !== 'string' || p.length === 0) return p;
  // 保留根（如 C:\ 或 \\server\share\）的最后一个分隔符
  const trimmed = p.replace(/[\\/]+$/, '');
  return trimmed.length === 0 ? p : trimmed;
}

/**
 * 路径等价比较：先字面相等，再忽略末尾分隔符比较。
 * 不做 realpath —— 那正是失败的那一步。
 */
function samePathLoose(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string') return false;
  if (left === right) return true;
  return trimTrailingSep(left) === trimTrailingSep(right);
}

export function apply(ctx) {
  const registry = ctx.workspaceRegistry;
  if (registry === void 0) {
    ctx.logger?.warn?.('[keep-grouped] workspaceRegistry 不可用，插件不生效');
    return;
  }

  const host = registry.host;
  if (host === void 0 || typeof host.candidateMatches !== 'function') {
    ctx.logger?.warn?.('[keep-grouped] registry.host.candidateMatches 不可用，插件不生效');
    return;
  }

  const original = host.candidateMatches;
  let rescued = 0;

  host.candidateMatches = function patchedCandidateMatches(id, path) {
    // 1) 原逻辑优先：网络正常时行为与官方完全一致
    let matched = false;
    try {
      matched = original.call(this, id, path);
    } catch {
      matched = false;
    }
    if (matched) return true;

    // 2) 兜底：拿会话 header 里的 cwd 做字面比较
    const header = registry.headers?.get?.(id);
    const cwd = header?.cwd;
    if (cwd === void 0) return false;
    if (!samePathLoose(cwd, path)) return false;

    rescued += 1;
    ctx.logger?.info?.(
      `[keep-grouped] 会话 ${id} 的 cwd 暂时无法解析，按字面路径保留在工作区（已累计保留 ${rescued} 个会话）`,
    );
    return true;
  };

  // 卸载时还原，避免热重载后重复包装
  ctx.effect(() => () => {
    host.candidateMatches = original;
  }, 'keep-grouped.restoreCandidateMatches');

  ctx.logger?.info?.('[keep-grouped] 已接管 candidateMatches：工作区路径暂时不可达时，会话仍留在原分组');
}
