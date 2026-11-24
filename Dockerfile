FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY src/HybridFailoverController/HybridFailoverController.csproj HybridFailoverController/
RUN dotnet restore HybridFailoverController/HybridFailoverController.csproj
COPY src/HybridFailoverController/ HybridFailoverController/
RUN dotnet publish HybridFailoverController/HybridFailoverController.csproj -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app
COPY --from=build /app ./
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
USER $APP_UID
ENTRYPOINT ["dotnet", "HybridFailoverController.dll"]
