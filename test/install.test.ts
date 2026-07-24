import { afterEach, describe, expect, it } from "bun:test";
import { execFile } from "node:child_process";
import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  readlink,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const repoRoot = path.resolve(import.meta.dirname, "..");
const installer = path.join(repoRoot, "install.sh");
const appDefinition = path.join(repoRoot, "app");
const temporaryRoots: string[] = [];

async function executable(file: string, source: string) {
  await writeFile(file, source, { mode: 0o755 });
  await chmod(file, 0o755);
}

async function fixture() {
  const root = await mkdtemp(path.join(os.tmpdir(), "benos-herdr-installer-"));
  temporaryRoots.push(root);
  const bin = path.join(root, "bin");
  const applications = path.join(root, "Applications");
  const state = path.join(root, "state");
  await mkdir(bin, { recursive: true });
  await executable(path.join(bin, "codesign"), "#!/usr/bin/env bash\nexit 0\n");
  await executable(
    path.join(bin, "ditto"),
    '#!/usr/bin/env bash\nset -euo pipefail\ncp -a "$3" "$4"\n',
  );

  const makeApp = async (name: string) => {
    const app = path.join(root, name, "Herdr.app");
    const executablePath = path.join(app, "Contents", "MacOS", "ghostty");
    await mkdir(path.dirname(executablePath), { recursive: true });
    await mkdir(path.join(app, "Contents", "Resources"), { recursive: true });
    await executable(executablePath, "#!/usr/bin/env bash\nexit 0\n");
    await writeFile(
      path.join(app, "Contents", "Resources", "herdr.ghostty"),
      "command = /bin/zsh -l -c 'exec herdr'\n",
    );
    return app;
  };

  const run = (...args: string[]) =>
    execFileAsync(
      installer,
      [
        ...args,
        "--applications-dir",
        applications,
        "--state-dir",
        state,
        "--no-launch",
      ],
      {
        env: {
          ...process.env,
          PATH: `${bin}:${process.env.PATH}`,
          HERDR_MACOS_INSTALLER_TESTING: "1",
        },
      },
    );

  return { applications, makeApp, run, state };
}

afterEach(async () => {
  await Promise.all(
    temporaryRoots
      .splice(0)
      .map((root) => rm(root, { recursive: true, force: true })),
  );
});

describe("Herdr macOS installer", () => {
  it("installs a real application bundle and rolls back", async () => {
    const f = await fixture();
    const first = await f.makeApp("source-one");
    const second = await f.makeApp("source-two");

    await f.run("--app", first, "--release-id", "release-one");
    await f.run("--app", second, "--release-id", "release-two");

    const current = path.join(f.applications, "Herdr.app");
    const currentStat = await lstat(current);
    expect(currentStat.isDirectory()).toBe(true);
    expect(currentStat.isSymbolicLink()).toBe(false);
    expect(await readlink(path.join(f.state, "current"))).toBe(
      path.join(f.state, "releases", "release-two", "Herdr.app"),
    );
    expect(await readlink(path.join(f.state, "previous"))).toBe(
      path.join(f.state, "releases", "release-one", "Herdr.app"),
    );
    expect(
      await readFile(path.join(f.state, "xdg", "ghostty", "config"), "utf8"),
    ).toBe(
      "command = /bin/zsh -l -c 'exec herdr'\n",
    );

    await f.run("--rollback");
    const rolledBackStat = await lstat(current);
    expect(rolledBackStat.isDirectory()).toBe(true);
    expect(rolledBackStat.isSymbolicLink()).toBe(false);
    expect(await readlink(path.join(f.state, "current"))).toBe(
      path.join(f.state, "releases", "release-one", "Herdr.app"),
    );
  });

  it("refuses to replace an unmanaged Herdr application", async () => {
    const f = await fixture();
    const source = await f.makeApp("source");
    await mkdir(path.join(f.applications, "Herdr.app"), { recursive: true });

    await expect(
      f.run("--app", source, "--release-id", "release-one"),
    ).rejects.toThrow(/Refusing to replace a non-managed app/);
  });

  it("migrates the legacy managed symlink to a real application bundle", async () => {
    const f = await fixture();
    const first = await f.makeApp("source-one");
    const second = await f.makeApp("source-two");
    const current = path.join(f.applications, "Herdr.app");
    const firstRelease = path.join(
      f.state,
      "releases",
      "release-one",
      "Herdr.app",
    );

    await f.run("--app", first, "--release-id", "release-one");
    await rm(current, { recursive: true });
    await rm(path.join(f.state, "current"));
    await symlink(firstRelease, current);

    await f.run("--app", second, "--release-id", "release-two");

    const currentStat = await lstat(current);
    expect(currentStat.isDirectory()).toBe(true);
    expect(currentStat.isSymbolicLink()).toBe(false);
    expect(await readlink(path.join(f.state, "previous"))).toBe(firstRelease);
  });

  it("retains only the active and rollback releases", async () => {
    const f = await fixture();
    const first = await f.makeApp("source-one");
    const second = await f.makeApp("source-two");
    const third = await f.makeApp("source-three");

    await f.run("--app", first, "--release-id", "release-one");
    await f.run("--app", second, "--release-id", "release-two");
    await f.run("--app", third, "--release-id", "release-three");

    expect(
      (await readdir(path.join(f.state, "releases"))).sort(),
    ).toEqual(["release-three", "release-two"]);
  });

  it("pins the verified source release and isolated Herdr configuration", async () => {
    const source = await readFile(installer, "utf8");
    const config = await readFile(
      path.join(appDefinition, "herdr.ghostty"),
      "utf8",
    );
    const keys = await readFile(path.join(appDefinition, "herdr-keys.toml"), "utf8");

    expect(source).toContain("ghostty_version='1.3.1'");
    expect(source).toContain(
      "ghostty_sha256='3349d25600ffbda281197a18314f7d18791969cffe9474f0ff16a45a9ebfccdb'",
    );
    expect(source).toContain(
      "RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV",
    );
    expect(source).toContain("New Herdr Tab Here");
    expect(source).toContain("${herdr_bundle_id}.dock-tile");
    expect(source).toContain("orderFrontStandardAboutPanel:");
    expect(source).toContain("png2icns");
    expect(config).not.toContain("config-default-files");
    expect(config).toContain("command = /bin/zsh -l -c 'exec herdr'");
    expect(config).toContain("env = NO_COLOR=");
    expect(source).toContain('set_plist "$plist" CFBundleExecutable ghostty');
    expect(source).toContain("LSEnvironment:XDG_CONFIG_HOME");
    expect(source).toContain("herdr config reset-keys");
    expect(source).toContain("/^# Managed by herdr-macos$/d");
    expect(source).toContain("LICENSE-HERDR-AGPL-3.0.txt");
    expect(source).toContain("LICENSE-GHOSTTY-MIT.txt");
    expect(source).not.toContain("launcher.c");
    expect(config).toContain("cmd+t=text:\\x02c");
    expect(config).toContain("cmd+n=text:\\x02N");
    expect(config).not.toContain("cmd+KeyT");
    expect(config).not.toContain("cmd+KeyN");
    expect(config).toContain("cmd+shift+KeyW=text:\\x02X");
    expect(config).toContain("cmd+shift+KeyR=text:\\x02W");
    expect(config).toContain("cmd+physical:one=text:\\x021");
    expect(config).toContain("cmd+1=text:\\x021");
    expect(config).toContain("cmd+physical:nine=text:\\x029");
    expect(config).toContain("cmd+9=text:\\x029");
    expect(config).not.toContain("\\x1b[49;6u");
    expect(config).not.toContain("\\x1b[57;6u");
    expect(keys).toContain('prefix = "ctrl+b"');
    expect(keys).not.toContain("new_tab");
    expect(keys).not.toContain("new_workspace");
    expect(keys).not.toContain("close_tab");
    expect(keys).not.toContain("rename_workspace");
  });

});
