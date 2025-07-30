def run(plan, args=None):
    if not args:
        args = {}
    
    # Load multi-chain configuration
    chains = args.get("chains", [])
    
    # Import required packages
    postgres = import_module("github.com/tiljrd/postgres-package@main/main.star")
    
    # Deploy PostgreSQL
    postgres_config = args.get("postgres", {})
    postgres_output = postgres.run(
        plan,
        service_name="postgres",
        min_cpu=postgres_config.get("min_cpu", 10),
        max_cpu=postgres_config.get("max_cpu", 1000),
        min_memory=postgres_config.get("min_memory", 32),
        max_memory=postgres_config.get("max_memory", 1024),
        extra_env_vars={
            "POSTGRES_INITDB_ARGS": "-E UTF8 --locale=C"
        }
    )
    
    # Deploy IPFS
    ipfs_output = plan.add_service(
        name="ipfs",
        config=ServiceConfig(
            image="ipfs/kubo:master-latest",
            ports={
                "rpc": PortSpec(number=5001, transport_protocol="TCP"),
                "p2p": PortSpec(number=4001, transport_protocol="TCP"),
                "gateway": PortSpec(number=8080, transport_protocol="TCP", application_protocol="http")
            }
        )
    )
    
    # Deploy firehose instances for each chain
    chain_configs = []
    for chain in chains:
        firehose_config = plan.render_templates(
            config={
                "firehose.yaml": struct(
                    template=read_file("templates/firehose.yaml.tmpl"),
                    data={"rpc_url": chain["rpc_url"]}
                )
            },
            name="firehose-config-{}".format(chain["key"])
        )
        
        firehose_service = plan.add_service(
            name="firehose-{}".format(chain["key"]),
            config=ServiceConfig(
                image="ghcr.io/streamingfast/firehose-ethereum:latest",
                ports={
                    "grpc": PortSpec(number=9000, transport_protocol="TCP", wait="1m"),
                    "api": PortSpec(number=10015, transport_protocol="TCP", wait="1m")
                },
                files={"/tmp/config/": firehose_config},
                entrypoint=["fireeth"],
                cmd=["start", "-c", "/tmp/config/firehose.yaml", "--advertise-block-features=base"]
            )
        )
        
        chain_config = {
            "key": chain["key"],
            "substreams_grpc": "http://{}:9000".format(firehose_service.ip_address),
            "substreams_token": "",
            "firehose_grpc": "http://{}:10015".format(firehose_service.ip_address),
            "firehose_token": ""
        }
        chain_configs.append(chain_config)
    
    # Deploy Graph Node with multi-chain configuration
    graph_node_config = plan.render_templates(
        config={
            "config.toml": struct(
                template=read_file("templates/config.toml.tmpl"),
                data={
                    "networks": chain_configs,
                    "postgres_user": postgres_output.user,
                    "postgres_pass": postgres_output.password,
                    "postgres_host": postgres_output.service.hostname,
                    "postgres_db": postgres_output.database
                }
            )
        },
        name="graph-node-config"
    )
    
    graph_node_config_env = args.get("graph_node", {})

    chain_names = [n["key"] for n in chains]
    disable_check_list = ",".join(chain_names)
    graph_output = plan.add_service(
        name="graph-node",
        config=ServiceConfig(
            image="graphprotocol/graph-node",
            ports={
                "http": PortSpec(number=8000, transport_protocol="TCP", application_protocol="http", wait=None),
                "ws": PortSpec(number=8001, transport_protocol="TCP", wait=None),
                "rpc": PortSpec(number=8020, transport_protocol="TCP", wait=None),
                "api": PortSpec(number=8030, transport_protocol="TCP", wait=None),
                "prometheus": PortSpec(number=8040, transport_protocol="TCP", wait=None)
            },
            env_vars={
                "postgres_host": postgres_output.service.hostname,
                "postgres_user": postgres_output.user,
                "postgres_pass": postgres_output.password,
                "postgres_db": postgres_output.database,
                "GRAPH_NODE_FIREHOSE_DISABLE_EXTENDED_BLOCKS_FOR_CHAINS": disable_check_list,
                "GRAPH_LOG": graph_node_config_env.get("log_level", "trace")
            },
            files={"/tmp/config/": graph_node_config},
            cmd=[
                "graph-node",
                "--config", "/tmp/config/config.toml",
                "--ipfs", "{}:5001".format(ipfs_output.ip_address),
                "--node-id", "block_ingestor_node"
            ]
        )
    )
    
    # Build and deploy substreams/subgraphs for each chain
    deploy_indexer_for_chains(plan, chains, graph_output, ipfs_output)
    
    return struct(
        postgres=postgres_output,
        ipfs=ipfs_output,
        graph=graph_output,
        chains=chain_configs
    )

def deploy_indexer_for_chains(plan, chains, graph_output, ipfs_output):
    # Upload subgraph and substreams directories first
    subgraph_files = plan.upload_files(
        src="./subgraph",
        name="subgraph-files"
    )
    
    substreams_files = plan.upload_files(
        src="./substreams", 
        name="substreams-files"
    )
    
    # Add indexer service for building and deploying substreams/subgraphs
    indexer_service = plan.add_service(
        name="indexer",
        config=ServiceConfig(
            image="node:20-alpine",
            env_vars={
                "GRAPH_NODE_URL": "http://{}:8020".format(graph_output.ip_address),
                "IPFS_URL": "http://{}:5001".format(ipfs_output.ip_address)
            },
            files={
                "/workspace/subgraph": subgraph_files,
                "/workspace/substreams": substreams_files
            },
            cmd=["sh", "-c", "apk add --no-cache curl git build-base python3 && sleep infinity"]
        )
    )
    
    # Wait for graph node to be ready
    plan.wait(
        service_name="graph-node",
        recipe=GetHttpRequestRecipe(endpoint="/", port_id="rpc"),
        field="code",
        assertion="==",
        target_value=405,
        interval="2s",
        timeout="2m"
    )
    
    # Install Graph CLI and subgraph dependencies
    plan.exec(
        service_name="indexer",
        recipe=ExecRecipe(
            command=["sh", "-c", "npm install -g @graphprotocol/graph-cli && cd /workspace/subgraph && npm install"]
        )
    )
    
    # Copy and rename existing substreams packages for each chain
    for chain in chains:
        plan.exec(
            service_name="indexer",
            recipe=ExecRecipe(
                command=["sh", "-c", "cp /workspace/substreams/sepolia.spkg /workspace/substreams/{}.spkg".format(chain["key"])]
            )
        )
    
    # Build and deploy substreams/subgraphs for each chain
    for chain in chains:
        # Generate subgraph config for this chain
        plan.exec(
            service_name="indexer",
            recipe=ExecRecipe(
                command=["sh", "-c", "cd /workspace/subgraph && cp subgraph_sepolia.yaml subgraph_{}.yaml".format(chain["key"])]
            )
        )
        
        # Update the subgraph config with chain-specific values
        plan.exec(
            service_name="indexer",
            recipe=ExecRecipe(
                command=["sh", "-c", "cd /workspace/subgraph && sed -i 's/sepolia/{}/g' subgraph_{}.yaml".format(chain["key"], chain["key"])]
            )
        )
        
        
        # Generate code from schema
        plan.exec(
            service_name="indexer",
            recipe=ExecRecipe(
                command=["sh", "-c", "cd /workspace/subgraph && graph codegen subgraph_{}.yaml".format(chain["key"])]
            )
        )
        
        # Create and deploy subgraph
        plan.exec(
            service_name="indexer",
            recipe=ExecRecipe(
                command=["sh", "-c", "cd /workspace/subgraph && graph create --node {} cctup/indexer_{}".format(
                    "http://{}:8020".format(graph_output.ip_address),
                    chain["key"]
                )]
            )
        )
        
        plan.exec(
            service_name="indexer",
            recipe=ExecRecipe(
                command=["sh", "-c", "cd /workspace/subgraph && graph deploy --node {} --ipfs {} --version-label v0.0.1 cctup/indexer_{} subgraph_{}.yaml".format(
                    "http://{}:8020".format(graph_output.ip_address),
                    "http://{}:5001".format(ipfs_output.ip_address),
                    chain["key"],
                    chain["key"]
                )]
            )
        )
