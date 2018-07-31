/*
 * Copyright 2004-2018 Cray Inc.
 * Other additional copyright holders may be indicated within.
 *
 * The entirety of this work is licensed under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 *
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */


use TOML;
use Spawn;
use MasonUtils;
use MasonHelp;
use MasonUpdate;
use MasonBuild;
use Path;
use FileSystem;

/* Runs the .chpl files found within the /example directory */
proc masonExample(args) {

  var show = true;
  var run = true;
  var build = true;
  var examples: [1..0] string;

  for arg in args {
    if arg == '--no-show' {
      show=false;
    }
    else if arg == '--no-run' {
      run=false;
    }
    else if arg == '--no-build' {
      build=false;
    }
    else {
      examples.push_back(arg);
    }
  }
  var uargs = [""];
  if !build then uargs.push_back("--no-update-registry");  
  UpdateLock(uargs);
  runExamples(show, run, build, examples);
}


private proc getBuildInfo(projectHome: string) {

  // parse lock and toml(examples dont make it to lock file)
  const lock = open(projectHome + "/Mason.lock", iomode.r);
  const toml = open(projectHome + "/Mason.toml", iomode.r);
  const lockFile = new Owned(parseToml(lock));
  const tomlFile = new Owned(parseToml(toml));
  
  // Get project source code and dependencies
  const sourceList = genSourceList(lockFile);
  getSrcCode(sourceList, false);
  const project = lockFile["root"]["name"].s;
  const projectPath = "".join(projectHome, "/src/", project, ".chpl");
  
  // get the example names from lockfile or from example directory
  const exampleNames = getExamples(tomlFile.borrow(), projectHome);

  // Get system, and external compopts
  const compopts = getTomlCompopts(lockFile.borrow(), [""]);
  const perExampleOptions = getExampleOptions(tomlFile.borrow(), exampleNames);

  // Close lock and toml
  lock.close();
  toml.close();


  return (sourceList, projectPath, compopts, exampleNames, perExampleOptions);
}

// retrieves compopts and execopts for each example.
// returns assoc array of <example_name> -> <(compopts, execopts)>
private proc getExampleOptions(toml: Toml, exampleNames: [?d] string) {

  var exampleDomain: domain(string);
  var exampleOptions: [exampleDomain] (string, string);
  for example in exampleNames {
    const exampleName = basename(stripExt(example, ".chpl"));
    exampleOptions[exampleName] = ("", "");
    if toml.pathExists("".join("examples.", exampleName, ".compopts")) {
      var compopts = toml["".join("examples.", exampleName)]["compopts"].s;
      exampleOptions[exampleName][1] = compopts;
    }
    if toml.pathExists("".join("examples.", exampleName, ".execopts")) {
      var execopts = toml["".join("examples.", exampleName)]["execopts"].s;
      exampleOptions[exampleName][2] = execopts;
    }
  }
  return exampleOptions;
}

// Cleans out example dir from a previous run
private proc setupExampleDir(projectHome: string, exampleNames: [?d] string) {

  const exampleDir = joinPath(projectHome, "target/example/");
  if isDir(exampleDir) {

    // prevent building one example from removing all.
    for example in exampleNames {
      const exampleName = stripExt(example, ".chpl");
      const exampleBinary = joinPath(exampleDir, exampleName);
      if isFile(exampleBinary) {
        remove(exampleBinary);
      }
    }
  }
  else {
    // Make target files if they dont exist from a build
    makeTargetFiles("debug", projectHome);
  }
}

// Takes in examples found by mason and examples requested by user
// outputs examples that should be built/run
private proc determineExamples(exampleNames: [?d1] string,
                               examplesRequested: [?d2] string) throws {

  var examplesToRun: [1..0] string;

  // check if user listed examples actually exist
  if examplesRequested.domain.size > 0 {
    for example in examplesRequested {
      if exampleNames.count(example) == 0 {
        throw new MasonError("Mason could not find example: " + example);
      }
      else {
        examplesToRun.push_back(example);
      }
    }
    return examplesToRun;
  }
  // user didnt list any examples, run all examples
  else return exampleNames;
}


private proc runExamples(show: bool, run: bool, build: bool,
                         examplesRequested: [?d] string) throws {

  try! {

    const cwd = getEnv("PWD");
    const projectHome = getProjectHome(cwd);

    // Get buildInfo: dependencies, path to src code, compopts,
    // names of examples, example compopts
    const buildInfo = getBuildInfo(projectHome);
    const sourceList = buildInfo[1];
    const projectPath = buildInfo[2];
    const compopts = buildInfo[3];
    const exampleNames = buildInfo[4];
    const perExampleOptions = buildInfo[5];

    var numExamples = exampleNames.domain.size;
    var examplesToRun = determineExamples(exampleNames, examplesRequested);

    // Clean out example binaries from previous runs
    if build then setupExampleDir(projectHome, examplesToRun);


    if numExamples > 0 {
      for example in examplesToRun {

        const examplePath = "".join(projectHome, '/example/', example);
        const exampleName = basename(stripExt(example, ".chpl"));

        // retrieves compopts and execopts found per example in the toml file
        const options = perExampleOptions[exampleName];
        const exampleCompopts = options[1];
        const exampleExecopts = options[2];

        if build {

          // get the string of dependencies for compilation
          // also names example as --main-module
          const masonCompopts = getMasonDependencies(sourceList, exampleName);
          const allCompOpts = " ".join(" ".join(compopts), masonCompopts,
                                      exampleCompopts);

          const moveTo = "-o " + projectHome + "/target/example/" + exampleName;
          const compCommand = " ".join("chpl",examplePath, projectPath,
                                       moveTo, allCompOpts);
          const compilation = runWithStatus(compCommand);

          if compilation != 0 {
            stderr.writeln("compilation failed for " + example);
          }
          else {
            if show || !run then writeln("compiled ", example, " successfully");
            if run {
              var result = runExampleBinary(projectHome, exampleName, show, exampleExecopts);
              if result != 0 {
                throw new MasonError("Failed to run example for: " + example);
              }
            }
          }
        }
        // just running the example
        else {
          var result = runExampleBinary(projectHome, exampleName, show, exampleExecopts);
          if result != 0 {
            throw new MasonError("Failed to run example for: " + example);
          }
        }
      }
    }
    else {
      throw new MasonError("No examples were found in /example");
    }
  }
  catch e: MasonError {
    stderr.writeln(e.message());
    exit(1);
  }
}


private proc runExampleBinary(projectHome: string, exampleName: string,
                              show: bool, execopts: string) throws {
  const command = "".join(projectHome,'/target/example/', exampleName, " ", execopts);
  const exampleResult = runWithStatus(command, show);
  return exampleResult;
}  


private proc getMasonDependencies(sourceList: [?d] (string, string, string),
                                 exampleName: string) {

  // Declare example to run as the main module
  var masonCompopts = " ".join(" --main-module", exampleName, " ");

  if sourceList.numElements > 0 {
    const depPath = MASON_HOME + "/src/";

    // Add dependencies to project
    for (_, name, version) in sourceList {
      var depSrc = "".join(' ',depPath, name, "-", version, '/src/', name, ".chpl");
      masonCompopts += depSrc;
    }
  }
  return masonCompopts;
}

private proc getExamples(toml: Toml, projectHome: string) {
  var exampleNames: [1..0] string;
  const examplePath = joinPath(projectHome, "example");

  if toml.pathExists("examples.examples") {

    var examples = toml["examples"]["examples"].toString();
    var strippedExamples = examples.split(',').strip('[]');
    for example in strippedExamples {
      const t = example.strip().strip('"');
      exampleNames.push_back(t);
    }
    return exampleNames;
  }
  else if isDir(examplePath) {
    var examples = findfiles(startdir=examplePath, recursive=true, hidden=false);
    for example in examples {
      if example.endsWith(".chpl") {
        exampleNames.push_back(getExamplePath(example));
      }
    }
    return exampleNames;
  }
  return exampleNames;
}

/* Gets the path of the example following the example dir */
proc getExamplePath(fullPath: string, examplePath = "") : string {
  var split = splitPath(fullPath);
  if split[2] == "example" {
    return examplePath;
  }
  else {
    if examplePath == "" {
      return getExamplePath(split[1], split[2]);
    }
    else {
      var appendedPath = joinPath(split[2], examplePath);
      return getExamplePath(split[1], appendedPath);
    }
  }
}

// used when user calls `mason run --example` without argument
proc printAvailableExamples(toml: Toml, projectHome: string) {
  const examples = getExamples(toml, projectHome);
  writeln("--- available examples ---");
  for example in examples {
    writeln(" --- " + example);
  }
  writeln("--------------------------");
}